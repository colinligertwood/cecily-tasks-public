import Foundation

/// An edit this device made that a delete on the server made pointless: the record was deleted
/// before (or while) the edit was sent. Reported only on the device that made the edit.
public struct LostEdit: Hashable, Sendable {
    public var id: RecordID
    public var fields: [String]
    /// The record as the server last had it, to say what it was.
    public var values: [String: SyncValue]

    public init(id: RecordID, fields: [String], values: [String: SyncValue] = [:]) {
        self.id = id
        self.fields = fields
        self.values = values
    }
}

/// Two devices changed the same long text (a note, say) before either had the other's change.
/// The change that reached the server last is kept; this is the other one, to keep as a copy.
public struct Conflict: Hashable, Sendable {
    public var id: RecordID
    public var field: String
    /// The text that didn't win.
    public var text: String

    public init(id: RecordID, field: String, text: String) {
        self.id = id
        self.field = field
        self.text = text
    }
}

/// What the store's data needs after a server event, and what to tell the engine.
public struct SyncOutcome: Sendable {
    /// Fields to write to local objects, creating them if needed. Fields this device has pending
    /// are left out: they're about to be sent, and will win.
    public var upserts: [ServerRecord] = []
    /// Objects to delete locally.
    public var deletions: [RecordID] = []
    public var lostEdits: [LostEdit] = []
    /// Long texts changed both here and elsewhere, whose other version is to be kept as a copy.
    public var conflicts: [Conflict] = []
    /// Changes to add to the engine's pending list, and ones to take off it.
    public var add: [PendingChange] = []
    public var remove: [PendingChange] = []

    public init() {}

    public mutating func merge(_ other: SyncOutcome) {
        upserts += other.upserts
        deletions += other.deletions
        lostEdits += other.lostEdits
        conflicts += other.conflicts
        add += other.add
        remove += other.remove
    }
}

/// What to send for a pending change.
public enum Outgoing: Hashable, Sendable {
    case save(ServerRecord)
    case delete(RecordID)
    /// Nothing to send any more: it's been dealt with, or the object is gone.
    case nothing
}

/// A store's sync state. The server is the source of truth: for each record this keeps what the
/// server last had, its change tag, and which fields this device has changed and not had
/// confirmed. A conflict is settled by re-applying those fields to the server's record, so the
/// last change to reach the server wins, field by field. For the fields in `conflictFields`, long
/// texts such as notes, the version that didn't win is reported as a `Conflict`. Saved with the
/// store's data.
public struct SyncState: Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        /// The server's values, as last seen. Empty for a record that has never been saved.
        public var server: [String: SyncValue] = [:]
        /// The server's change tag; nil until the record has been saved.
        public var tag: Data?
        /// Fields changed here and not yet confirmed, each with the version of its last change, so
        /// a field changed again while it was being sent stays pending.
        public var pending: [String: Int] = [:]
        /// Deleted here, and not yet on the server.
        public var pendingDelete = false

        public var hasBeenSaved: Bool { tag != nil }
    }

    /// Written only through `put`, so `changed` stays right.
    public private(set) var entries: [RecordID: Entry] = [:]
    private var version = 0
    /// Records whose entries changed since `takeChanged()`, so only those need saving.
    public private(set) var changed: Set<RecordID> = []
    /// The versions of the fields being sent, by record. Not saved: after a relaunch, unconfirmed
    /// fields are simply sent again.
    private var inFlight: [RecordID: [String: (version: Int, value: SyncValue)]] = [:]
    /// Records fetched since the last `didFetch`, to tell which ones a from-scratch fetch missed.
    private var seenThisFetch: Set<RecordID> = []

    /// For each record type, the long-text fields whose losing version is kept as a copy. Not
    /// saved: it's part of the app, set when the state is opened.
    public var conflictFields: [String: Set<String>] = [:]
    /// For each record type, the lists that only grow, whose arriving values are written even
    /// while this device's change to them is pending, to be added to it. Not saved.
    public var mergedFields: [String: Set<String>] = [:]

    public init() {}

    /// Sync state as saved, entry by entry.
    public init(entries: [RecordID: Entry]) {
        self.entries = entries
        version = entries.values.flatMap(\.pending.values).max() ?? 0
        changed = []
    }

    /// The records whose entries changed since the last call (an entry that's gone was removed),
    /// and starts counting afresh.
    public mutating func takeChanged() -> Set<RecordID> {
        defer { changed = [] }
        return changed
    }

    public subscript(id: RecordID) -> Entry? { entries[id] }

    /// Every change waiting to be sent, as the engine should have it.
    public var pendingChanges: [PendingChange] {
        entries.compactMap { id, entry in
            if entry.pendingDelete { return .delete(id) }
            return entry.pending.isEmpty ? nil : .save(id)
        }.sorted { $0.id < $1.id }
    }

    // MARK: - Local changes

    /// An object changed here: its synced values as they are now. Fields that differ from the
    /// server's become pending; a record the server has never had sends every field.
    public mutating func recordLocal(_ id: RecordID, values: [String: SyncValue]) -> SyncOutcome {
        var entry = entries[id] ?? Entry()
        var outcome = SyncOutcome()
        if entry.pendingDelete {
            // Back after a delete (undo, say): it's an edit again.
            entry.pendingDelete = false
            outcome.remove.append(.delete(id))
        }
        for (field, value) in values where !Self.same(value, entry.server[field]) || !entry.hasBeenSaved {
            version += 1
            entry.pending[field] = version
        }
        put(id, entry)
        if !entry.pending.isEmpty { outcome.add.append(.save(id)) }
        return outcome
    }

    /// An object was deleted here. One the server has never had is just forgotten, unless its
    /// first save is on its way: the server will have it then, so it's deleted after.
    public mutating func recordLocalDelete(_ id: RecordID) -> SyncOutcome {
        guard var entry = entries[id] else { return SyncOutcome() }
        var outcome = SyncOutcome()
        outcome.remove.append(.save(id))
        let beingSaved = inFlight.removeValue(forKey: id) != nil
        if entry.hasBeenSaved || beingSaved {
            entry.pending = [:]
            entry.pendingDelete = true
            put(id, entry)
            outcome.add.append(.delete(id))
        } else {
            put(id, nil)
        }
        return outcome
    }

    /// What to send for a pending change, given the object's synced values now (nil if it's gone).
    /// Only the pending fields go: the server keeps the rest.
    public mutating func outgoing(_ change: PendingChange, current: [String: SyncValue]?) -> Outgoing {
        guard let entry = entries[change.id] else { return .nothing }
        switch change {
        case .save(let id):
            guard !entry.pendingDelete, !entry.pending.isEmpty, let current else { return .nothing }
            var fields: [String: SyncValue] = [:]
            var sent: [String: (version: Int, value: SyncValue)] = [:]
            for (field, version) in entry.pending {
                let value = current[field] ?? .null
                fields[field] = value
                sent[field] = (version, value)
            }
            inFlight[id] = sent
            return .save(ServerRecord(id: id, tag: entry.tag, fields: fields))
        case .delete(let id):
            return entry.pendingDelete ? .delete(id) : .nothing
        }
    }

    // MARK: - Results of sending

    /// The server saved a record. Fields confirmed as sent stop being pending; a field changed
    /// again meanwhile stays, and is sent again.
    public mutating func saved(_ record: ServerRecord) -> SyncOutcome {
        guard var entry = entries[record.id] else { return SyncOutcome() }
        // Just saved, so it exists: a fetch from scratch under way mustn't take it for deleted.
        seenThisFetch.insert(record.id)
        let sent = inFlight.removeValue(forKey: record.id) ?? [:]
        entry.tag = record.tag
        for (field, value) in record.fields { entry.server[field] = value }
        for (field, item) in sent {
            entry.server[field] = item.value
            if entry.pending[field] == item.version { entry.pending[field] = nil }
        }
        put(record.id, entry)
        var outcome = SyncOutcome()
        if !entry.pending.isEmpty && !entry.pendingDelete { outcome.add.append(.save(record.id)) }
        return outcome
    }

    /// The server deleted a record this device deleted.
    public mutating func deleted(_ id: RecordID) -> SyncOutcome {
        put(id, nil)
        inFlight[id] = nil
        return SyncOutcome()
    }

    /// The server refused a save.
    public mutating func failed(_ id: RecordID, _ failure: SaveFailure) -> SyncOutcome {
        let sent = inFlight.removeValue(forKey: id) ?? [:]
        guard var entry = entries[id] else { return SyncOutcome() }
        var outcome = SyncOutcome()
        switch failure {
        case .changed(let server):
            // Someone else's change got there first: take the server's record, keep this device's
            // pending fields on top, and send them again.
            seenThisFetch.insert(id)
            if !entry.pendingDelete {
                outcome.conflicts = conflicts(id, entry, arriving: server.fields, mine: sent.mapValues(\.value))
            }
            entry.server = server.fields
            entry.tag = server.tag
            put(id, entry)
            if !entry.pendingDelete {
                outcome.upserts.append(withoutPending(server, entry))
            }
            outcome.add.append(entry.pendingDelete ? .delete(id) : .save(id))
        case .deleted:
            // Deleted on the server: the delete wins. An edit that never got there is lost.
            if !entry.pendingDelete && !entry.pending.isEmpty {
                outcome.lostEdits.append(LostEdit(id: id, fields: entry.pending.keys.sorted(), values: entry.server))
            }
            put(id, nil)
            if !entry.pendingDelete { outcome.deletions.append(id) }
            outcome.remove += [.save(id), .delete(id)]
        case .batchFailed, .other:
            outcome.add.append(entry.pendingDelete ? .delete(id) : .save(id))
        }
        return outcome
    }

    // MARK: - Fetching

    /// Changes fetched from the server.
    public mutating func fetched(modifications: [ServerRecord], deletions: [RecordID]) -> SyncOutcome {
        var outcome = SyncOutcome()
        for record in modifications {
            seenThisFetch.insert(record.id)
            var entry = entries[record.id] ?? Entry()
            if !entry.pendingDelete {
                outcome.conflicts += conflicts(record.id, entry, arriving: record.fields, mine: (inFlight[record.id] ?? [:]).mapValues(\.value))
            }
            entry.server = record.fields
            entry.tag = record.tag
            put(record.id, entry)
            // Deleted here: the delete goes when it's sent, whatever arrived.
            if !entry.pendingDelete {
                outcome.upserts.append(withoutPending(record, entry))
            }
        }
        for id in deletions {
            outcome.merge(removeDeletedOnServer(id))
        }
        return outcome
    }

    /// A zone's fetch has finished. After a fetch from scratch, records this device has from the
    /// server that weren't in it were deleted while it wasn't looking. Records never saved stay,
    /// to be sent.
    public mutating func didFetch(fromScratch: Bool) -> SyncOutcome {
        defer { seenThisFetch = [] }
        guard fromScratch else { return SyncOutcome() }
        var outcome = SyncOutcome()
        for (id, entry) in entries where entry.hasBeenSaved && !seenThisFetch.contains(id) {
            outcome.merge(removeDeletedOnServer(id))
        }
        return outcome
    }

    private mutating func removeDeletedOnServer(_ id: RecordID) -> SyncOutcome {
        guard let entry = entries[id] else { return SyncOutcome() }
        put(id, nil)
        inFlight[id] = nil
        var outcome = SyncOutcome()
        if !entry.pendingDelete {
            if !entry.pending.isEmpty {
                outcome.lostEdits.append(LostEdit(id: id, fields: entry.pending.keys.sorted(), values: entry.server))
            }
            outcome.deletions.append(id)
        }
        outcome.remove += [.save(id), .delete(id)]
        return outcome
    }

    // MARK: - Helpers

    /// Long texts this device has changed and not had confirmed, which arrive changed by someone
    /// else too. A value that matches what this device is sending isn't a conflict.
    private func conflicts(_ id: RecordID, _ entry: Entry, arriving: [String: SyncValue], mine: [String: SyncValue]) -> [Conflict] {
        guard let fields = conflictFields[id.type], entry.hasBeenSaved else { return [] }
        return entry.pending.keys.sorted().compactMap { field in
            guard fields.contains(field), let value = arriving[field], !Self.same(value, entry.server[field]) else { return nil }
            if let sent = mine[field], Self.same(value, sent) { return nil }
            guard let text = value.stringValue, !text.isEmpty else { return nil }
            return Conflict(id: id, field: field, text: text)
        }
    }

    private mutating func put(_ id: RecordID, _ entry: Entry?) {
        entries[id] = entry
        changed.insert(id)
    }

    /// The record with this device's pending fields taken out, for writing locally, except lists
    /// that only grow, which are added to.
    private func withoutPending(_ record: ServerRecord, _ entry: Entry) -> ServerRecord {
        var record = record
        let merged = mergedFields[record.id.type] ?? []
        for field in entry.pending.keys where !merged.contains(field) { record.fields[field] = nil }
        return record
    }

    /// Whether a local value is what the server has. A missing field and an empty one are the
    /// same (CloudKit may not keep an empty string, list or data), and so are a boolean and the
    /// integer CloudKit stores it as.
    public static func same(_ a: SyncValue, _ b: SyncValue?) -> Bool {
        normalized(a) == normalized(b ?? .null)
    }

    private static func normalized(_ value: SyncValue) -> SyncValue {
        switch value {
        case .bool(let b): .int(b ? 1 : 0)
        case .string(""), .strings([]), .data(Data()): .null
        default: value
        }
    }
}

extension SyncState: Codable {
    private enum CodingKeys: String, CodingKey {
        case entries, version
    }

    private struct Pair: Codable {
        var id: RecordID
        var entry: Entry
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pairs = try c.decode([Pair].self, forKey: .entries)
        entries = Dictionary(pairs.map { ($0.id, $0.entry) }, uniquingKeysWith: { a, _ in a })
        version = try c.decode(Int.self, forKey: .version)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries.map { Pair(id: $0.key, entry: $0.value) }.sorted { $0.id < $1.id }, forKey: .entries)
        try c.encode(version, forKey: .version)
    }
}
