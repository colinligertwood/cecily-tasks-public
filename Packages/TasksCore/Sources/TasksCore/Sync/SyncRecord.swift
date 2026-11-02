import Foundation

/// Identifies a record within a zone: its type (a model name such as `Item`) and its name within
/// that type (the model's `id`).
public struct RecordID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var type: String
    public var name: String

    public init(type: String, name: String) {
        self.type = type
        self.name = name
    }

    public init(type: String, uid: UUID) {
        self.init(type: type, name: uid.uuidString)
    }

    public static func < (lhs: RecordID, rhs: RecordID) -> Bool {
        (lhs.type, lhs.name) < (rhs.type, rhs.name)
    }

    public var description: String { "\(type)/\(name)" }
}

/// A record as the server has it, or as it's sent there. `tag` is the server's change tag (for
/// CloudKit, the record's encoded system fields): nil for a record that has never been saved.
/// When saving, `fields` holds only what changed; the server keeps the rest.
public struct ServerRecord: Hashable, Sendable {
    public var id: RecordID
    public var tag: Data?
    public var fields: [String: SyncValue]

    public init(id: RecordID, tag: Data?, fields: [String: SyncValue]) {
        self.id = id
        self.tag = tag
        self.fields = fields
    }
}

/// Something waiting to go to the server: a record to save, or one to delete. The content of a
/// save is asked for when it's sent (see `SyncEngineDelegate.nextBatch`).
public enum PendingChange: Hashable, Codable, Sendable {
    case save(RecordID)
    case delete(RecordID)

    public var id: RecordID {
        switch self {
        case .save(let id), .delete(let id): id
        }
    }
}

/// What the server said about a save it refused.
public enum SaveFailure: Hashable, Sendable {
    /// The server has a newer copy (or the record exists, for one sent without a tag). Comes with
    /// the server's record.
    case changed(ServerRecord)
    /// The record was deleted.
    case deleted
    /// Part of an atomic batch in which another save was refused.
    case batchFailed
    /// Anything else (offline, quota, and so on): it stays pending and is tried again.
    case other(String)
}

/// Saves and deletes to send together. An atomic batch is all or nothing.
public struct SyncBatch: Sendable {
    public var saves: [ServerRecord]
    public var deletes: [RecordID]
    public var atomic: Bool

    public init(saves: [ServerRecord], deletes: [RecordID], atomic: Bool) {
        self.saves = saves
        self.deletes = deletes
        self.atomic = atomic
    }

    public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
}

/// What a sync engine tells its delegate, after the shape of `CKSyncEngine`'s events.
public enum SyncEvent: Sendable {
    /// Changes from the server, in pages. Apply them before the state update that follows.
    case fetched(zone: String, modifications: [ServerRecord], deletions: [RecordID])
    /// A zone's fetch has finished. `fromScratch` means it started from nothing (a first fetch, an
    /// expired change token, lost state), so deletions made meanwhile weren't reported: anything
    /// this device has from the server that wasn't fetched was deleted.
    case didFetch(zone: String, fromScratch: Bool)
    /// What happened to a batch.
    case sent(zone: String, saved: [ServerRecord], failed: [RecordID: SaveFailure], deleted: [RecordID])
}

/// The side of sync that knows the data: one per zone, given the events for its zone.
@MainActor
public protocol SyncEngineDelegate: AnyObject {
    /// The next batch to send for a zone, from what's pending, or nil when there's nothing more.
    func nextBatch(zone: String, pending: [PendingChange]) -> SyncBatch?
    func handle(_ event: SyncEvent)
}

/// Moves a database's zones to and from the server: `CKSyncEngine` in the app, `MemorySyncEngine`
/// in tests and the self-test.
@MainActor
public protocol SyncEngine: AnyObject {
    func add(_ changes: [PendingChange], zone: String)
    func remove(_ changes: [PendingChange], zone: String)
    func sendChanges() async throws
    func fetchChanges() async throws
}
