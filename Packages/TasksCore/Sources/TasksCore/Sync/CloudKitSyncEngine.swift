import CloudKit
import Foundation
import os

/// A `SyncEngine` over `CKSyncEngine`, for one CloudKit database. One engine serves every zone in
/// its database, as Apple recommends, and each zone's coordinator is its delegate. (Cecily Tasks
/// has one zone, in the private database.)
///
/// - **Sending:** the coordinators build the batches (see `SyncEngineDelegate.nextBatch`).
///   Changes are taken off the engine's list when their result comes back; the coordinator puts
///   back what still has to go.
/// - **Fetching** covers only zones attached here.
/// - **Bindings:** the engine's change tokens are its own, shared by its zones, so it notes which
///   store each zone's changes went to. A zone attached by a different store (the data reset and
///   downloaded again, say) is read in full from the server, since the engine's token for it may
///   have moved on without that store. So is a zone whose fetch from scratch was cut short.
@MainActor
public final class CloudKitSyncEngine: SyncEngine, CKSyncEngineDelegate {
    /// What the app needs to hear about beyond records.
    public enum Notice: Sendable {
        case accountChanged(CKSyncEngine.Event.AccountChange.ChangeType)
        /// A zone was deleted from the server, by another device or by resetting iCloud data.
        case zoneDeleted(String, CKDatabase.DatabaseChange.Deletion.Reason)
        /// A zone in use isn't on the server: not made yet, or gone.
        case zoneNotFound(String)
        /// Zones were added or deleted in this database.
        case zonesChanged
        /// Something went wrong that isn't about one record.
        case problem(String)
    }

    /// The engine's saved state.
    struct Saved: Codable {
        var state: CKSyncEngine.State.Serialization?
        /// For each zone the engine has fetched, the store its changes went to.
        var bindings: [String: String] = [:]
        /// Zones whose engine fetch started from scratch and hasn't finished.
        var scratch: Set<String> = []
    }

    private struct Zone {
        weak var delegate: SyncEngineDelegate?
        var schema: CloudKitSchema
        var binding: String
    }

    public nonisolated let database: CKDatabase
    /// Called with the engine's state to save whenever it changes, after the records that came
    /// before it have been delivered.
    public var stateDidChange: ((Data) -> Void)?
    public var notice: ((Notice) -> Void)?

    private var saved: Saved
    private var zones: [String: Zone] = [:]
    /// Attached zones to read in full before the engine fetches them.
    private var needsFullFetch: Set<String> = []
    private var fullFetching: Set<String> = []
    private var made: CKSyncEngine?
    /// Records in a batch whose result hasn't come back.
    private var inFlight: Set<CKRecord.ID> = []
    /// How often each record has gone out during this round of sending, so one CloudKit keeps
    /// refusing can't hold the round up.
    private var offered: [CKRecord.ID: Int] = [:]
    /// Where asset contents wait for CloudKit to upload them.
    private let assetFolder: URL
    private let log = Logger(subsystem: "com.ligertwood.cecily.tasks", category: "cloudkit")

    private static let interrupted = "(interrupted)"
    private static let dropped = "(dropped)"

    public init(database: CKDatabase, state data: Data?) {
        self.database = database
        assetFolder = FileManager.default.temporaryDirectory.appending(path: "CloudKitAssets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: assetFolder, withIntermediateDirectories: true)
        var saved = data.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        if saved.state == nil {
            // Starting afresh: every zone's first fetch is from scratch.
            saved.bindings = [:]
            saved.scratch = []
        } else {
            for zone in saved.scratch { saved.bindings[zone] = Self.interrupted }
            saved.scratch = []
        }
        self.saved = saved
    }

    /// Made on first use, since it needs this object as its delegate. It then fetches and sends
    /// by itself: at launch, on pushes, on a schedule, and soon after changes are added.
    private var engine: CKSyncEngine {
        if let made { return made }
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: saved.state, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        made = engine
        return engine
    }

    // MARK: - Zones

    /// Starts delivering a zone's changes to its coordinator. `binding` identifies the store.
    public func attach(_ delegate: SyncEngineDelegate, schema: CloudKitSchema, binding: String) {
        let name = schema.zoneID.zoneName
        zones[name] = Zone(delegate: delegate, schema: schema, binding: binding)
        switch saved.bindings[name] {
        case binding:
            break
        case nil:
            // Never fetched by this engine, so its first fetch starts from scratch.
            saved.bindings[name] = binding
            saved.scratch.insert(name)
            saveState()
        default:
            needsFullFetch.insert(name)
        }
        _ = engine
    }

    /// Stops delivering a zone's changes. With `dropPending`, what was waiting to go is forgotten.
    public func detach(zone name: String, dropPending: Bool) {
        zones[name] = nil
        needsFullFetch.remove(name)
        guard dropPending, let made else { return }
        made.state.remove(pendingRecordZoneChanges: made.state.pendingRecordZoneChanges.filter { $0.recordID.zoneID.zoneName == name })
        made.state.remove(pendingDatabaseChanges: made.state.pendingDatabaseChanges.filter { $0.zoneID.zoneName == name })
    }

    /// Makes a zone on the server, before anything is saved in it.
    public func createZone(_ zoneID: CKRecordZone.ID) {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    public var hasPendingChanges: Bool {
        guard let made else { return false }
        return !made.state.pendingRecordZoneChanges.isEmpty || !made.state.pendingDatabaseChanges.isEmpty
    }

    // MARK: - SyncEngine

    public func add(_ changes: [PendingChange], zone name: String) {
        guard let zone = zones[name], !changes.isEmpty else { return }
        let pending = changes.map { pendingChange($0, zone: zone) }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    public func remove(_ changes: [PendingChange], zone name: String) {
        guard let zone = zones[name], !changes.isEmpty, let made else { return }
        let pending = changes.map { pendingChange($0, zone: zone) }
        made.state.remove(pendingRecordZoneChanges: pending)
    }

    public func sendChanges() async throws {
        try await engine.sendChanges()
    }

    /// Reads in full any zone that needs it, then fetches the others' changes. The database's
    /// changes come first, to learn which zones changed: a fetch limited to named zones fetches
    /// only those already known to have changed, so it would find nothing new.
    public func fetchChanges() async throws {
        for name in needsFullFetch.sorted() {
            try await fullFetch(name)
        }
        guard !fetchableZoneIDs.isEmpty else { return }
        try await engine.fetchChanges()
    }

    /// Attached zones that the engine itself fetches.
    private var fetchableZoneIDs: [CKRecordZone.ID] {
        zones.filter { !needsFullFetch.contains($0.key) }.map(\.value.schema.zoneID)
    }

    private func pendingChange(_ change: PendingChange, zone: Zone) -> CKSyncEngine.PendingRecordZoneChange {
        let id = zone.schema.recordID(change.id)
        switch change {
        case .save: return .saveRecord(id)
        case .delete: return .deleteRecord(id)
        }
    }

    private func recordID(_ ck: CKRecord.ID, zone: Zone) -> RecordID? {
        zone.schema.recordID(ck)
    }

    // MARK: - Reading a zone in full

    private func fullFetch(_ name: String) async throws {
        guard let zoneID = zones[name]?.schema.zoneID, fullFetching.insert(name).inserted else { return }
        defer { fullFetching.remove(name) }
        var token: CKServerChangeToken?
        var more = true
        while more {
            let page:
                (
                    modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                    deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool
                )
            do {
                page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                // Nothing to read. The coordinator decides whether that's a zone still to be made
                // or one that's gone.
                notice?(.zoneNotFound(name))
                finishFullFetch(name, delivered: false)
                return
            }
            guard zones[name] != nil else { return }
            let records = page.modificationResultsByID.values.compactMap { try? $0.get().record }
            deliver(records, deletions: [], zone: name)
            token = page.changeToken
            more = page.moreComing
        }
        finishFullFetch(name, delivered: true)
    }

    private func finishFullFetch(_ name: String, delivered: Bool) {
        guard let zone = zones[name] else { return }
        if delivered { zone.delegate?.handle(.didFetch(zone: name, fromScratch: true)) }
        needsFullFetch.remove(name)
        saved.bindings[name] = zone.binding
        saved.scratch.remove(name)
        saveState()
    }

    // MARK: - Delivering

    private func deliver(_ records: [CKRecord], deletions: [CKDatabase.RecordZoneChange.Deletion], zone name: String) {
        guard let zone = zones[name], let delegate = zone.delegate else { return }
        let modifications = records.compactMap { zone.schema.serverRecord($0) }
        let deleted = deletions.compactMap { recordID($0.recordID, zone: zone) }
        guard !modifications.isEmpty || !deleted.isEmpty else { return }
        delegate.handle(.fetched(zone: name, modifications: modifications, deletions: deleted))
    }

    private func didSend(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        var saved: [String: [ServerRecord]] = [:]
        var failed: [String: [RecordID: SaveFailure]] = [:]
        var deleted: [String: [RecordID]] = [:]
        var done: [CKSyncEngine.PendingRecordZoneChange] = []
        var missingZones: Set<String> = []

        for ck in sent.savedRecords {
            inFlight.remove(ck.recordID)
            let name = ck.recordID.zoneID.zoneName
            guard let zone = zones[name], let id = recordID(ck.recordID, zone: zone) else { continue }
            done.append(.saveRecord(ck.recordID))
            // Only the tag: the saved record may not carry the fields that weren't sent, and the
            // coordinator knows what it sent.
            saved[name, default: []].append(ServerRecord(id: id, tag: CloudKitSchema.systemFields(of: ck), fields: [:]))
        }
        for failure in sent.failedRecordSaves {
            let ckID = failure.record.recordID
            inFlight.remove(ckID)
            let name = ckID.zoneID.zoneName
            guard let zone = zones[name], let id = recordID(ckID, zone: zone) else { continue }
            done.append(.saveRecord(ckID))
            let reason: SaveFailure
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord, let record = zone.schema.serverRecord(server) {
                    reason = .changed(record)
                } else {
                    reason = .other(failure.error.localizedDescription)
                }
            case .unknownItem:
                reason = .deleted
            case .batchRequestFailed:
                reason = .batchFailed
            case .zoneNotFound, .userDeletedZone:
                missingZones.insert(name)
                reason = .other(failure.error.localizedDescription)
            default:
                log.error("Couldn't save \(ckID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
                reason = .other(failure.error.localizedDescription)
            }
            failed[name, default: [:]][id] = reason
        }
        for ckID in sent.deletedRecordIDs {
            inFlight.remove(ckID)
            let name = ckID.zoneID.zoneName
            guard let zone = zones[name], let id = recordID(ckID, zone: zone) else { continue }
            done.append(.deleteRecord(ckID))
            deleted[name, default: []].append(id)
        }
        for (ckID, error) in sent.failedRecordDeletes {
            inFlight.remove(ckID)
            let name = ckID.zoneID.zoneName
            if error.code == .unknownItem, let zone = zones[name], let id = recordID(ckID, zone: zone) {
                // Already gone: that's done.
                done.append(.deleteRecord(ckID))
                deleted[name, default: []].append(id)
            } else {
                if error.code == .zoneNotFound || error.code == .userDeletedZone { missingZones.insert(name) }
                // Left on the list; the engine tries again.
                log.error("Couldn't delete \(ckID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        made?.state.remove(pendingRecordZoneChanges: done)
        for name in Set(saved.keys).union(failed.keys).union(deleted.keys).sorted() {
            zones[name]?.delegate?.handle(.sent(zone: name, saved: saved[name] ?? [], failed: failed[name] ?? [:], deleted: deleted[name] ?? []))
        }
        for name in missingZones.sorted() { notice?(.zoneNotFound(name)) }
    }

    private func saveState() {
        if let stateDidChange, let data = try? JSONEncoder().encode(saved) { stateDidChange(data) }
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saved.state = update.stateSerialization
            saveState()
        case .accountChange(let change):
            notice?(.accountChanged(change.changeType))
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions {
                notice?(.zoneDeleted(deletion.zoneID.zoneName, deletion.reason))
            }
            if !changes.modifications.isEmpty || !changes.deletions.isEmpty { notice?(.zonesChanged) }
        case .fetchedRecordZoneChanges(let changes):
            let records = Dictionary(grouping: changes.modifications.map(\.record)) { $0.recordID.zoneID.zoneName }
            let deletions = Dictionary(grouping: changes.deletions) { $0.recordID.zoneID.zoneName }
            for name in Set(records.keys).union(deletions.keys).sorted() {
                guard zones[name] != nil, !needsFullFetch.contains(name) else {
                    // Fetching skips these, so this shouldn't happen; if it does, whichever store
                    // uses the zone next reads it in full.
                    if zones[name] == nil { saved.bindings[name] = Self.dropped }
                    continue
                }
                deliver(records[name] ?? [], deletions: deletions[name] ?? [], zone: name)
            }
        case .didFetchRecordZoneChanges(let fetched):
            let name = fetched.zoneID.zoneName
            if let error = fetched.error {
                if error.code == .zoneNotFound || error.code == .userDeletedZone { notice?(.zoneNotFound(name)) }
                log.error("Couldn't fetch \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } else if let zone = zones[name], !needsFullFetch.contains(name) {
                let fromScratch = saved.scratch.remove(name) != nil
                zone.delegate?.handle(.didFetch(zone: name, fromScratch: fromScratch))
                if fromScratch { saveState() }
            }
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error(
                    "Couldn't create zone \(failure.zone.zoneID.zoneName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
                notice?(.problem(failure.error.localizedDescription))
            }
        case .sentRecordZoneChanges(let sent):
            didSend(sent)
        case .willSendChanges:
            offered = [:]
        case .didSendChanges:
            inFlight = []
            offered = [:]
        case .didFetchChanges:
            // A zone still to be read in full (its first try failed, say) is tried again.
            for name in needsFullFetch.sorted() where !fullFetching.contains(name) {
                Task { [weak self] in try? await self?.fullFetch(name) }
            }
        case .willFetchChanges, .willFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine
        .RecordZoneChangeBatch?
    {
        let scope = context.options.scope
        var order: [String] = []
        var byZone: [String: [CKSyncEngine.PendingRecordZoneChange]] = [:]
        for change in syncEngine.state.pendingRecordZoneChanges where scope.contains(change) {
            let id = change.recordID
            guard !inFlight.contains(id), offered[id, default: 0] < 3 else { continue }
            let name = id.zoneID.zoneName
            if byZone[name] == nil { order.append(name) }
            byZone[name, default: []].append(change)
        }
        for name in order {
            guard let zone = zones[name], let delegate = zone.delegate else { continue }
            var pending: [PendingChange] = []
            var unknown: [CKSyncEngine.PendingRecordZoneChange] = []
            for change in byZone[name] ?? [] {
                guard let id = recordID(change.recordID, zone: zone) else {
                    unknown.append(change)
                    continue
                }
                switch change {
                case .saveRecord: pending.append(.save(id))
                case .deleteRecord: pending.append(.delete(id))
                @unknown default: unknown.append(change)
                }
            }
            // Left over from before a relaunch or sync stopping: the coordinator puts back
            // everything it still has to send when it's attached.
            if !unknown.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: unknown) }
            guard let batch = delegate.nextBatch(zone: name, pending: pending), !batch.isEmpty else { continue }
            var records: [CKRecord] = []
            for save in batch.saves {
                do {
                    records.append(try zone.schema.ckRecord(save, assetFolder: assetFolder))
                } catch {
                    log.error("Couldn't encode \(save.id.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            let deletes = batch.deletes.map { zone.schema.recordID($0) }
            for id in records.map(\.recordID) + deletes {
                inFlight.insert(id)
                offered[id, default: 0] += 1
            }
            if records.isEmpty && deletes.isEmpty { continue }
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: deletes, atomicByZone: batch.atomic)
        }
        return nil
    }

    public func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async
        -> CKSyncEngine.FetchChangesOptions
    {
        CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(fetchableZoneIDs))
    }
}

extension CKSyncEngine.PendingRecordZoneChange {
    var recordID: CKRecord.ID {
        switch self {
        case .saveRecord(let id), .deleteRecord(let id): id
        @unknown default: fatalError("Unknown pending change")
        }
    }
}

extension CKSyncEngine.PendingDatabaseChange {
    var zoneID: CKRecordZone.ID {
        switch self {
        case .saveZone(let zone): zone.zoneID
        case .deleteZone(let id): id
        @unknown default: fatalError("Unknown pending change")
        }
    }
}
