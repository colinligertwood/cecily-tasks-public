import Foundation

/// A stand-in for CloudKit, for tests. It follows what the real server was checked to do:
///
/// - a save with an old change tag, or a new record (no tag) whose name exists, is refused with
///   the server's record;
/// - a save with the tag of a deleted record is refused as deleted, and the record stays deleted;
/// - a new record (no tag) with a deleted record's name is accepted;
/// - a save sends only changed fields, and the server keeps the rest;
/// - deleting a record that's gone succeeds;
/// - an atomic batch with one refused save saves nothing;
/// - zone changes give each changed record's latest state, or its deletion, in pages; a fetch
///   from scratch gives only the records that exist; old change tokens can expire.
@MainActor
public final class MemoryServer {
    public enum Failure: Error, Equatable {
        case offline
        case zoneNotFound(String)
        case tokenExpired
    }

    public struct Page: Sendable {
        public var modifications: [ServerRecord]
        public var deletions: [RecordID]
        public var token: Int
        public var moreComing: Bool
    }

    private struct Stored {
        var fields: [String: SyncValue]
        var tag: Data
    }

    private struct Zone {
        var records: [RecordID: Stored] = [:]
        /// The sequence number of each record's latest change, deletions included.
        var changed: [RecordID: Int] = [:]
        /// Change tokens handed out and not expired, each standing for a place in the changes.
        var tokens: [Int: Int] = [:]
    }

    private var zones: [String: Zone] = [:]
    private var sequence = 0
    private var lastToken = 0

    public init() {}

    public func createZone(_ zone: String) {
        if zones[zone] == nil { zones[zone] = Zone() }
    }

    public func deleteZone(_ zone: String) {
        zones[zone] = nil
    }

    /// Saves and deletes, as one request.
    public func modify(zone name: String, batch: SyncBatch) throws -> (saved: [ServerRecord], failed: [RecordID: SaveFailure], deleted: [RecordID]) {
        guard var zone = zones[name] else { throw Failure.zoneNotFound(name) }
        var failed: [RecordID: SaveFailure] = [:]
        for save in batch.saves {
            if let failure = refusal(save, in: zone) { failed[save.id] = failure }
        }
        if batch.atomic && !failed.isEmpty {
            for save in batch.saves where failed[save.id] == nil { failed[save.id] = .batchFailed }
            for id in batch.deletes { failed[id] = .batchFailed }
            return ([], failed, [])
        }
        var saved: [ServerRecord] = []
        for save in batch.saves where failed[save.id] == nil {
            var stored = zone.records[save.id] ?? Stored(fields: [:], tag: Data())
            for (field, value) in save.fields {
                stored.fields[field] = value == .null ? nil : value
            }
            stored.tag = Self.newTag()
            zone.records[save.id] = stored
            sequence += 1
            zone.changed[save.id] = sequence
            saved.append(ServerRecord(id: save.id, tag: stored.tag, fields: stored.fields))
        }
        var deleted: [RecordID] = []
        for id in batch.deletes {
            if zone.records.removeValue(forKey: id) != nil {
                sequence += 1
                zone.changed[id] = sequence
            }
            deleted.append(id)
        }
        zones[name] = zone
        return (saved, failed, deleted)
    }

    private func refusal(_ save: ServerRecord, in zone: Zone) -> SaveFailure? {
        if let stored = zone.records[save.id] {
            return save.tag == stored.tag ? nil : .changed(ServerRecord(id: save.id, tag: stored.tag, fields: stored.fields))
        }
        return save.tag == nil ? nil : .deleted
    }

    /// Changes since a token (nil: from scratch), up to `limit` records.
    public func changes(zone name: String, since token: Int?, limit: Int) throws -> Page {
        guard var zone = zones[name] else { throw Failure.zoneNotFound(name) }
        var after = -1
        if let token {
            guard let place = zone.tokens[token] else { throw Failure.tokenExpired }
            after = place
        }
        let changed = zone.changed
            .filter { $0.value > after && (token != nil || zone.records[$0.key] != nil) }
            .sorted { $0.value < $1.value }
        let page = changed.prefix(limit)
        var modifications: [ServerRecord] = []
        var deletions: [RecordID] = []
        for (id, _) in page {
            if let stored = zone.records[id] {
                modifications.append(ServerRecord(id: id, tag: stored.tag, fields: stored.fields))
            } else {
                deletions.append(id)
            }
        }
        let moreComing = changed.count > page.count
        lastToken += 1
        zone.tokens[lastToken] = moreComing ? page.last!.value : sequence
        zones[name] = zone
        return Page(modifications: modifications, deletions: deletions, token: lastToken, moreComing: moreComing)
    }

    /// Makes every token handed out so far expire, as CloudKit can.
    public func expireTokens(zone name: String) {
        zones[name]?.tokens = [:]
    }

    // MARK: - Looking inside, for tests

    public func record(_ id: RecordID, zone: String) -> ServerRecord? {
        zones[zone]?.records[id].map { ServerRecord(id: id, tag: $0.tag, fields: $0.fields) }
    }

    public func records(zone: String) -> [RecordID: [String: SyncValue]] {
        (zones[zone]?.records ?? [:]).mapValues(\.fields)
    }

    private static func newTag() -> Data {
        withUnsafeBytes(of: UUID().uuid) { Data($0) }
    }
}

/// A `SyncEngine` over a `MemoryServer`, for one device's database: it drives each zone's
/// delegate the way `CKSyncEngine` does, asking for batches to send and delivering fetched pages,
/// then `didFetch`. Its state (change tokens and pending changes) can be saved and restored, as
/// after a relaunch.
@MainActor
public final class MemorySyncEngine: SyncEngine {
    public struct State: Codable {
        public var tokens: [String: Int] = [:]
        public var pending: [String: [PendingChange]] = [:]
    }

    private final class Box {
        weak var delegate: SyncEngineDelegate?
        init(_ delegate: SyncEngineDelegate) { self.delegate = delegate }
    }

    public let server: MemoryServer
    /// Requests fail while offline, as they would without a network.
    public var isOffline = false
    /// Records per fetched page.
    public var pageSize = 100
    /// Called with the engine's state after each change to it, once what came before has been
    /// delivered.
    public var stateDidChange: ((Data) -> Void)?

    private var state: State
    private var delegates: [String: Box] = [:]

    public init(server: MemoryServer, state: Data? = nil) {
        self.server = server
        self.state = state.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    public func attach(_ delegate: SyncEngineDelegate, zone: String) {
        delegates[zone] = Box(delegate)
    }

    public func detach(zone: String) {
        delegates[zone] = nil
    }

    public func pending(zone: String) -> [PendingChange] {
        state.pending[zone] ?? []
    }

    public func add(_ changes: [PendingChange], zone: String) {
        var list = state.pending[zone] ?? []
        for change in changes where !list.contains(change) { list.append(change) }
        state.pending[zone] = list
    }

    public func remove(_ changes: [PendingChange], zone: String) {
        state.pending[zone]?.removeAll { changes.contains($0) }
    }

    public func sendChanges() async throws {
        if isOffline { throw MemoryServer.Failure.offline }
        for (zone, box) in delegates.sorted(by: { $0.key < $1.key }) {
            guard let delegate = box.delegate else { continue }
            // Refused saves are queued again by the delegate; give up on a zone that makes no
            // progress rather than loop.
            for _ in 0..<50 {
                guard let batch = delegate.nextBatch(zone: zone, pending: pending(zone: zone)), !batch.isEmpty else { break }
                remove(batch.saves.map { .save($0.id) } + batch.deletes.map { .delete($0) }, zone: zone)
                let result = try server.modify(zone: zone, batch: batch)
                delegate.handle(.sent(zone: zone, saved: result.saved, failed: result.failed, deleted: result.deleted))
                let stuck =
                    result.saved.isEmpty && result.deleted.isEmpty
                    && result.failed.values.allSatisfy { if case .other = $0 { true } else { false } }
                if stuck { break }
            }
        }
        saveState()
    }

    public func fetchChanges() async throws {
        if isOffline { throw MemoryServer.Failure.offline }
        for (zone, box) in delegates.sorted(by: { $0.key < $1.key }) {
            guard let delegate = box.delegate else { continue }
            var token = state.tokens[zone]
            var fromScratch = token == nil
            var restarted = false
            while true {
                let page: MemoryServer.Page
                do {
                    page = try server.changes(zone: zone, since: token, limit: pageSize)
                } catch MemoryServer.Failure.tokenExpired where !restarted {
                    // Start again from scratch, once: a token from that can't have expired.
                    token = nil
                    fromScratch = true
                    restarted = true
                    continue
                }
                delegate.handle(.fetched(zone: zone, modifications: page.modifications, deletions: page.deletions))
                token = page.token
                state.tokens[zone] = token
                saveState()
                if !page.moreComing { break }
            }
            delegate.handle(.didFetch(zone: zone, fromScratch: fromScratch))
        }
    }

    private func saveState() {
        if let stateDidChange, let data = try? JSONEncoder().encode(state) { stateDidChange(data) }
    }
}
