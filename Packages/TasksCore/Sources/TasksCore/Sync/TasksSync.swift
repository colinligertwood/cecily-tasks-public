import Foundation
import OSLog
import SwiftData

/// Sync's own state, kept in the store so it's saved together with the records it describes. Not
/// synced.
@Model
public final class SyncZoneState {
    public var zoneName: String = TasksSync.zoneName
    /// Identifies this store to the sync engine, which notes where each zone's changes went.
    public var binding: String = UUID().uuidString
    /// Encoded `DefaultHistoryToken`: the store's history has been read up to here.
    public var historyToken: Data?
    /// The built-in contexts and settings this device made wait for the first full fetch: the
    /// server's copies, from a device that synced first, win over them.
    public var seedsWaiting: Bool = true

    public init() {}
}

/// One record's sync state: the server's values and change tag, and what's waiting to go.
@Model
public final class SyncEntryRow {
    /// `type/name`.
    @Attribute(.unique) public var key: String = ""
    /// The encoded `SyncState.Entry`.
    public var data: Data = Data()

    public init(key: String, data: Data) {
        self.key = key
        self.data = data
    }

    static func key(_ id: RecordID) -> String { "\(id.type)/\(id.name)" }

    static func recordID(_ key: String) -> RecordID? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        return RecordID(type: String(key[..<slash]), name: String(key[key.index(after: slash)...]))
    }
}

/// Syncs the store with one zone of a sync engine (`CloudKitSyncEngine` in the app,
/// `MemorySyncEngine` in tests), as Cecily Cards syncs a ledger. The server is the source of
/// truth; `SyncState` keeps what it last had and what this device has changed since.
///
/// - **Local edits** are read from the store's change history after each save and recorded as
///   pending fields. Sync's own writes carry its author name and aren't edits.
/// - **Received records** are written to the store straight away, parents first. A reference to
///   a record that hasn't arrived yet is linked when it does, and isn't sent back empty meanwhile.
/// - **Conflicts:** the last change to reach the server wins, field by field. When two devices
///   changed the same long text, the other version is kept as a `ConflictedCopy` for 30 days.
/// - **Sync state** is saved in the store, in the same save as the records it describes.
///
/// Every step works in a fresh context, so it reads what's saved. SwiftData doesn't bring one
/// context's saves into another, so when sync changes records it says so (`objectsDidChange`).
@MainActor
public final class TasksSync: SyncEngineDelegate {
    public nonisolated static let author = "tasks-sync"
    public nonisolated static let zoneName = "Tasks"
    /// Records in one batch, below CloudKit's limit of 400 per request.
    static let batchLimit = 300

    public enum Problem: Error, LocalizedError {
        case notSynced

        public var errorDescription: String? { "Sync isn't set up for this store." }
    }

    public let container: ModelContainer
    public let engine: any SyncEngine
    /// Identifies this store to the engine (see `CloudKitSyncEngine`).
    public let binding: String

    /// Edits made here that a delete elsewhere made pointless, each described in words.
    public var editsLost: (([String]) -> Void)?
    /// Something went wrong reading or writing the store.
    public var problem: ((String) -> Void)?
    /// Sync changed records (not just its own bookkeeping).
    public var objectsDidChange: (() -> Void)?
    /// Something came from the server or reached it.
    public var didExchange: ((Exchange) -> Void)?

    /// What one event from the engine did.
    public enum Exchange: Sendable {
        /// Records saved and deleted on the server, and saves it refused, with why.
        case sent(saved: Int, deleted: Int, refused: [String])
        /// Records that arrived, and deletions.
        case received(changed: Int, deleted: Int)
        /// A fetch has finished.
        case fetched
    }

    private var state: SyncState
    private var historyToken: DefaultHistoryToken?
    private var seedsWaiting: Bool
    /// References to records that haven't arrived, by the record they point to.
    private var dangling: [RecordID: Set<Link>] = [:]
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var captureScheduled = false
    private let log = Logger(subsystem: "com.ligertwood.cecily.tasks", category: "sync")

    private struct Link: Hashable {
        var child: RecordID
        var field: String
    }

    // MARK: - Setting up

    /// Starts syncing: what's in the store already is to be sent, except the built-in records,
    /// which wait for the first full fetch (see `SyncZoneState.seedsWaiting`).
    public static func begin(container: ModelContainer) throws {
        let context = ModelContext(container)
        try clear(context)
        let info = SyncZoneState()
        context.insert(info)
        if let token = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).last?.token {
            info.historyToken = try JSONEncoder().encode(token)
        }
        context.author = author
        try context.save()
    }

    /// Stops syncing: forgets the sync state. The data stays.
    public static func stop(container: ModelContainer) throws {
        let context = ModelContext(container)
        try clear(context)
        context.author = author
        try context.save()
    }

    public static func isSyncing(_ container: ModelContainer) -> Bool {
        ((try? ModelContext(container).fetchCount(FetchDescriptor<SyncZoneState>())) ?? 0) > 0
    }

    private static func clear(_ context: ModelContext) throws {
        try context.delete(model: SyncZoneState.self)
        try context.delete(model: SyncEntryRow.self)
    }

    public init(container: ModelContainer, engine: any SyncEngine) throws {
        let context = ModelContext(container)
        guard let info = try context.fetch(FetchDescriptor<SyncZoneState>()).first else { throw Problem.notSynced }
        self.container = container
        self.engine = engine
        binding = info.binding
        seedsWaiting = info.seedsWaiting
        historyToken = info.historyToken.flatMap { try? JSONDecoder().decode(DefaultHistoryToken.self, from: $0) }
        let decoder = JSONDecoder()
        var entries: [RecordID: SyncState.Entry] = [:]
        for row in try context.fetch(FetchDescriptor<SyncEntryRow>()) {
            guard let id = SyncEntryRow.recordID(row.key), let entry = try? decoder.decode(SyncState.Entry.self, from: row.data) else { continue }
            entries[id] = entry
        }
        state = SyncState(entries: entries)
        state.conflictFields = SyncModels.longTextFields
        state.mergedFields = SyncModels.mergedFields
        for (id, entry) in entries {
            for (field, target) in SyncModels.byType[id.type]?.references ?? [:] {
                guard let name = entry.server[field]?.stringValue else { continue }
                let targetID = RecordID(type: target, name: name)
                if state[targetID] == nil { dangling[targetID, default: []].insert(Link(child: id, field: field)) }
            }
        }
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let saved = note.object as? ModelContext
            MainActor.assumeIsolated {
                if let saved { self?.contextDidSave(saved) }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// After attaching to the engine: reads edits made while sync wasn't running, gives the engine
    /// everything waiting to go, and clears out old conflicted copies.
    public func resume() {
        captureLocalChanges()
        engine.add(state.pendingChanges, zone: Self.zoneName)
        let cutoff = Date.now.addingTimeInterval(-ConflictedCopy.keptFor)
        let context = ModelContext(container)
        context.author = Self.author
        try? context.delete(model: ConflictedCopy.self, where: #Predicate { $0.createdAt < cutoff })
        try? context.save()
    }

    /// The first time this store syncs: every object is to be sent, apart from built-in records
    /// nobody has changed, which wait for the first full fetch.
    public func recordEverything() {
        let context = ModelContext(container)
        var outcome = SyncOutcome()
        for model in SyncModels.all {
            record(model, ids: nil, context: context, outcome: &outcome, skipUntouchedSeeds: true)
        }
        let writing = ModelContext(container)
        commit(writing) { apply(outcome, context: writing) }
    }

    public var hasPendingChanges: Bool {
        !state.pendingChanges.isEmpty
    }

    public var pendingCount: Int {
        state.pendingChanges.count
    }

    // MARK: - Local edits

    private func contextDidSave(_ context: ModelContext) {
        guard context.container === container, context.author != Self.author else { return }
        guard !captureScheduled else { return }
        captureScheduled = true
        // Shortly, so a burst of saves is read at once.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            captureScheduled = false
            captureLocalChanges()
        }
    }

    /// Records everything saved since the last call, other than sync's own writes.
    public func captureLocalChanges() {
        let context = ModelContext(container)
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = historyToken {
            descriptor.predicate = #Predicate { $0.token > token }
        }
        let history: [DefaultHistoryTransaction]
        do {
            history = try context.fetchHistory(descriptor)
        } catch {
            report("Couldn't read the changes", error)
            return
        }
        guard let last = history.last else { return }

        var touched: [String: Set<PersistentIdentifier>] = [:]
        var deleted: [RecordID] = []
        for transaction in history where transaction.author != Self.author {
            for change in transaction.changes {
                let entity = change.changedPersistentIdentifier.entityName
                guard let model = SyncModels.byType[Self.recordType(forEntity: entity)] else { continue }
                switch change {
                case .insert, .update:
                    touched[model.recordType, default: []].insert(change.changedPersistentIdentifier)
                case .delete(let delete):
                    if let name = Self.tombstoneName(model, delete) { deleted.append(RecordID(type: model.recordType, name: name)) }
                @unknown default:
                    break
                }
            }
        }

        var outcome = SyncOutcome()
        for id in Self.parentsFirst(deleted) {
            outcome.merge(state.recordLocalDelete(id))
        }
        for model in SyncModels.all {
            guard let ids = touched[model.recordType] else { continue }
            record(model, ids: ids, context: context, outcome: &outcome, skipUntouchedSeeds: false)
        }
        historyToken = last.token
        log.notice("Read \(history.count) saved changes: \(touched.values.map(\.count).reduce(0, +)) records changed, \(deleted.count) deleted")
        let writing = ModelContext(container)
        commit(writing) { apply(outcome, context: writing) }
    }

    /// Records objects as they are now: those with these identifiers, or all of them.
    private func record<T: SyncModel>(
        _ type: T.Type, ids: Set<PersistentIdentifier>?, context: ModelContext, outcome: inout SyncOutcome, skipUntouchedSeeds: Bool
    ) {
        let all = (try? context.fetch(FetchDescriptor<T>())) ?? []
        let objects = ids.map { ids in all.filter { ids.contains($0.persistentModelID) } } ?? all
        for object in objects {
            if skipUntouchedSeeds, Self.isUntouchedSeed(object) { continue }
            outcome.merge(state.recordLocal(object.recordID, values: values(of: object)))
        }
    }

    /// The built-in records every device makes for itself, while nobody has changed them.
    private static func isUntouchedSeed(_ object: some SyncModel) -> Bool {
        switch object {
        case let context as Context: context.isBuiltIn && context.modifiedAt == context.createdAt
        case let settings as AppSettings: settings.modifiedAt == settings.createdAt
        default: false
        }
    }

    /// An object's synced values. A reference whose target hasn't arrived reads as empty on the
    /// object; it keeps the server's value, so it isn't sent back empty.
    private func values<T: SyncModel>(of object: T) -> [String: SyncValue] {
        var values = object.syncFields()
        let id = object.recordID
        for (field, target) in T.references where values[field] == .null {
            guard state[id]?.pending[field] == nil, let name = state[id]?.server[field]?.stringValue else { continue }
            if state[RecordID(type: target, name: name)] == nil { values[field] = .string(name) }
        }
        return values
    }

    // MARK: - SyncEngineDelegate

    public func nextBatch(zone: String, pending: [PendingChange]) -> SyncBatch? {
        captureLocalChanges()
        let links = SyncLinks(context: ModelContext(container))
        var remaining = pending
        while !remaining.isEmpty {
            let together = Array(remaining.prefix(Self.batchLimit))
            remaining.removeFirst(together.count)
            var batch = SyncBatch(saves: [], deletes: [], atomic: false)
            var nothing: [PendingChange] = []
            for change in together {
                switch state.outgoing(change, current: currentValues(change.id, links: links)) {
                case .save(let record): batch.saves.append(record)
                case .delete(let id): batch.deletes.append(id)
                case .nothing: nothing.append(change)
                }
            }
            if !nothing.isEmpty { engine.remove(nothing, zone: zone) }
            if !batch.isEmpty { return batch }
        }
        return nil
    }

    private func currentValues(_ id: RecordID, links: SyncLinks) -> [String: SyncValue]? {
        guard let model = SyncModels.byType[id.type] else { return nil }
        return currentValues(model, id.name, links: links)
    }

    private func currentValues<T: SyncModel>(_ type: T.Type, _ name: String, links: SyncLinks) -> [String: SyncValue]? {
        links.object(T.self, name).map { values(of: $0) }
    }

    public func handle(_ event: SyncEvent) {
        // Edits not read yet go first, so what arrives doesn't overwrite them.
        captureLocalChanges()
        let writing = ModelContext(container)
        var outcome = SyncOutcome()
        var finishedFullFetch = false
        let exchange: Exchange
        switch event {
        case .fetched(_, let modifications, let deletions):
            log.notice("Received \(modifications.count) changed records and \(deletions.count) deletions")
            outcome = state.fetched(modifications: modifications, deletions: deletions)
            exchange = .received(changed: modifications.count, deleted: deletions.count)
        case .didFetch(_, let fromScratch):
            log.notice("Fetch finished\(fromScratch ? " (from scratch)" : "", privacy: .public)")
            outcome = state.didFetch(fromScratch: fromScratch)
            finishedFullFetch = fromScratch
            exchange = .fetched
        case .sent(_, let saved, let failed, let deleted):
            for record in saved { outcome.merge(state.saved(record)) }
            for id in deleted { outcome.merge(state.deleted(id)) }
            for (id, failure) in failed.sorted(by: { $0.key < $1.key }) { outcome.merge(state.failed(id, failure)) }
            var refused: [String] = []
            for (id, failure) in failed.sorted(by: { $0.key < $1.key }) {
                guard case .other(let reason) = failure else { continue }
                log.error("iCloud refused \(id.description, privacy: .public): \(reason, privacy: .public)")
                refused.append(reason)
            }
            log.notice("Sent \(saved.count) records and \(deleted.count) deletions; \(failed.count) to send again")
            exchange = .sent(saved: saved.count, deleted: deleted.count, refused: refused)
        }
        commit(writing) {
            apply(outcome, context: writing)
            if finishedFullFetch && seedsWaiting { sendSeedsTheServerLacks(writing) }
        }
        didExchange?(exchange)
    }

    /// After the first full fetch: built-in records the server didn't have are this device's to
    /// send.
    private func sendSeedsTheServerLacks(_ context: ModelContext) {
        seedsWaiting = false
        var outcome = SyncOutcome()
        for model in SyncModels.all {
            recordUnsentSeeds(model, context: context, outcome: &outcome)
        }
        apply(outcome, context: context)
    }

    private func recordUnsentSeeds<T: SyncModel>(_ type: T.Type, context: ModelContext, outcome: inout SyncOutcome) {
        for object in (try? context.fetch(FetchDescriptor<T>())) ?? [] where Self.isUntouchedSeed(object) && state[object.recordID] == nil {
            outcome.merge(state.recordLocal(object.recordID, values: values(of: object)))
        }
    }

    // MARK: - Applying

    private func apply(_ outcome: SyncOutcome, context: ModelContext) {
        let links = SyncLinks(context: context)
        var arrived: [RecordID] = []
        for record in outcome.upserts.sorted(by: { Self.order($0.id) < Self.order($1.id) }) {
            // A type from a newer version of the app stays in the sync state only.
            guard let model = SyncModels.byType[record.id.type] else { continue }
            if upsert(model, record, links: links) { arrived.append(record.id) }
        }
        link(arrived, links: links)
        for id in outcome.deletions {
            if let model = SyncModels.byType[id.type] { delete(model, id.name, links: links) }
        }
        keepConflicts(outcome.conflicts, links: links)
        if !outcome.lostEdits.isEmpty {
            log.notice("Lost \(outcome.lostEdits.count) edits to records deleted elsewhere")
            editsLost?(outcome.lostEdits.map(describe))
        }
        engine.remove(outcome.remove, zone: Self.zoneName)
        engine.add(outcome.add, zone: Self.zoneName)
    }

    /// Writes a record to its object, making the object if it's new. True if it was made.
    private func upsert<T: SyncModel>(_ type: T.Type, _ record: ServerRecord, links: SyncLinks) -> Bool {
        links.missing = []
        var made = false
        let object: T
        if let existing = links.object(T.self, record.id.name) {
            // Writing what it already has would still count as a change.
            let differing = Self.differingFields(record, for: existing)
            if differing.isEmpty { return false }
            object = existing
        } else {
            object = T.make(from: record)
            links.context.insert(object)
            links.register(object)
            made = true
        }
        object.apply(record, links)
        for field in links.missing {
            guard let value = record.fields[field] else { continue }
            let names = value.stringValue.map { [$0] } ?? value.stringsValue ?? []
            let target = T.references[field] ?? Self.listTarget(T.self, field)
            for name in names {
                guard let target else { continue }
                dangling[RecordID(type: target, name: name), default: []].insert(Link(child: record.id, field: field))
            }
        }
        return made
    }

    /// The type a list of references points to.
    private static func listTarget<T: SyncModel>(_ type: T.Type, _ field: String) -> String? {
        switch (T.recordType, field) {
        case ("Item", "contexts"): Context.recordType
        default: nil
        }
    }

    /// The fields of a fetched record that its object doesn't have yet. A date may come back
    /// rounded to the millisecond.
    private static func differingFields(_ record: ServerRecord, for object: some SyncModel) -> [String] {
        let current = object.syncFields()
        return record.fields.filter { field, value in
            let local = current[field] ?? .null
            if let server = value.dateValue, let date = local.dateValue {
                return abs(server.timeIntervalSince(date)) >= 0.001
            }
            return !SyncState.same(value, local)
        }
        .keys.sorted()
    }

    /// Links references waiting for records that have just arrived.
    private func link(_ arrived: [RecordID], links: SyncLinks) {
        for target in arrived {
            guard let waiting = dangling.removeValue(forKey: target) else { continue }
            for link in waiting {
                guard let model = SyncModels.byType[link.child.type], let value = state[link.child]?.server[link.field] else { continue }
                relink(model, link.child.name, field: link.field, value: value, links: links)
            }
        }
    }

    private func relink<T: SyncModel>(_ type: T.Type, _ name: String, field: String, value: SyncValue, links: SyncLinks) {
        guard let object = links.object(T.self, name) else { return }
        object.apply(ServerRecord(id: object.recordID, tag: nil, fields: [field: value]), links)
    }

    private func delete<T: SyncModel>(_ type: T.Type, _ name: String, links: SyncLinks) {
        guard let object = links.object(T.self, name) else { return }
        links.context.delete(object)
        links.forget(T.self, name)
    }

    /// Keeps the other version of each long text changed here and elsewhere at once, unless it's
    /// the same as this device's.
    private func keepConflicts(_ conflicts: [Conflict], links: SyncLinks) {
        for conflict in conflicts {
            guard let model = SyncModels.byType[conflict.id.type] else { continue }
            let mine = currentValues(model, conflict.id.name, links: links)?[conflict.field]?.stringValue
            guard mine != conflict.text else { continue }
            log.notice("Keeping a conflicted copy of a \(conflict.id.type, privacy: .public)'s \(conflict.field, privacy: .public)")
            links.context.insert(
                ConflictedCopy(recordType: conflict.id.type, recordName: conflict.id.name, field: conflict.field, text: conflict.text))
        }
    }

    // MARK: - Saving

    /// Runs `body`, which writes to `context`, then saves it with the sync state under sync's
    /// author name.
    private func commit(_ context: ModelContext, _ body: () -> Void) {
        body()
        do {
            try saveState(context)
            guard context.hasChanges else { return }
            let changed = (context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray)
                .contains { !($0 is SyncEntryRow) && !($0 is SyncZoneState) }
            context.author = Self.author
            try context.save()
            if changed { objectsDidChange?() }
        } catch {
            report("Couldn't save sync changes", error)
        }
    }

    private func saveState(_ context: ModelContext) throws {
        let changed = state.takeChanged()
        if !changed.isEmpty {
            let keys = changed.map(SyncEntryRow.key)
            let rows =
                changed.count > 500
                ? try context.fetch(FetchDescriptor<SyncEntryRow>())
                : try context.fetch(FetchDescriptor<SyncEntryRow>(predicate: #Predicate { keys.contains($0.key) }))
            var byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let encoder = JSONEncoder()
            for id in changed {
                let key = SyncEntryRow.key(id)
                if let entry = state[id] {
                    let data = try encoder.encode(entry)
                    if let row = byKey[key] {
                        if row.data != data { row.data = data }
                    } else {
                        let row = SyncEntryRow(key: key, data: data)
                        context.insert(row)
                        byKey[key] = row
                    }
                } else if let row = byKey[key] {
                    context.delete(row)
                }
            }
        }
        if let info = try context.fetch(FetchDescriptor<SyncZoneState>()).first {
            let token = try historyToken.map { try JSONEncoder().encode($0) }
            if info.historyToken != token { info.historyToken = token }
            if info.seedsWaiting != seedsWaiting { info.seedsWaiting = seedsWaiting }
        }
    }

    private func report(_ what: String, _ error: Error) {
        log.error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
        problem?("\(what). \(error.localizedDescription)")
    }

    // MARK: - Helpers

    /// What a record was, for the lost edits notice: "The item “Call Sam”".
    private func describe(_ lost: LostEdit) -> String {
        let title = lost.values["title"]?.stringValue ?? lost.values["name"]?.stringValue ?? ""
        let noun =
            switch lost.id.type {
            case "Item": "item"
            case "Project": "project"
            case "Area": "area"
            case "Context": "context"
            case "Meeting": "meeting"
            case "MeetingSession": "meeting's notes"
            case "Attachment": "attachment"
            case "Goal": "goal"
            default: "record"
            }
        return title.isEmpty ? "A \(noun)" : "The \(noun) “\(title)”"
    }

    /// The record type of a SwiftData entity: they share names, except the repeat rule's.
    static func recordType(forEntity entity: String) -> String {
        entity == "Repetition" ? Repetition.recordType : entity
    }

    private static func order(_ id: RecordID) -> Int {
        SyncModels.byType[id.type]?.applyOrder ?? .max
    }

    private static func parentsFirst(_ ids: [RecordID]) -> [RecordID] {
        ids.sorted { order($0) != order($1) ? order($0) < order($1) : $0 < $1 }
    }

    private static func tombstoneName<T: SyncModel>(_ type: T.Type, _ delete: any HistoryDelete) -> String? {
        (delete as? DefaultHistoryDelete<T>).flatMap { T.recordName(from: $0.tombstone) }
    }
}
