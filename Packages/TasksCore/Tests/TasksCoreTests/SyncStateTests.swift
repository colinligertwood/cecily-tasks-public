import Foundation
import Testing

@testable import TasksCore

/// One device in a test: its objects (a dictionary standing in for the store), its sync state and
/// its engine, which talks to a shared `MemoryServer`.
@MainActor
final class TestDevice: SyncEngineDelegate {
    nonisolated static let zone = "Tasks"

    var store: [RecordID: [String: SyncValue]] = [:]
    var state = SyncState()
    var engine: MemorySyncEngine
    var lostEdits: [LostEdit] = []
    var conflicts: [Conflict] = []
    var engineState: Data?
    /// Records that save together, all or nothing.
    var group: (RecordID) -> String? = { _ in nil }
    var batchLimit = 400

    init(_ server: MemoryServer) {
        engine = MemorySyncEngine(server: server)
        state.conflictFields = ["Item": ["body"]]
        attach()
    }

    private func attach() {
        engine.attach(self, zone: Self.zone)
        engine.stateDidChange = { [weak self] in self?.engineState = $0 }
    }

    // MARK: - Local edits

    func set(_ id: RecordID, _ fields: [String: SyncValue]) {
        store[id, default: [:]].merge(fields) { $1 }
        apply(state.recordLocal(id, values: store[id]!))
    }

    func delete(_ id: RecordID) {
        store[id] = nil
        apply(state.recordLocalDelete(id))
    }

    func sync() async throws {
        try await engine.sendChanges()
        try await engine.fetchChanges()
    }

    /// Quits and relaunches: sync state and engine state come back from what was saved.
    func relaunch(_ server: MemoryServer) throws {
        let saved = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(SyncState.self, from: saved)
        state.conflictFields = ["Item": ["body"]]
        engine = MemorySyncEngine(server: server, state: engineState)
        attach()
    }

    // MARK: - Delegate

    func nextBatch(zone: String, pending: [PendingChange]) -> SyncBatch? {
        guard let first = pending.first else { return nil }
        // A group goes on its own, atomically; anything else in batches.
        let together: [PendingChange]
        if let name = group(first.id) {
            together = pending.filter { group($0.id) == name }
        } else {
            together = Array(pending.filter { group($0.id) == nil }.prefix(batchLimit))
        }
        var batch = SyncBatch(saves: [], deletes: [], atomic: group(first.id) != nil)
        var nothing: [PendingChange] = []
        for change in together {
            switch state.outgoing(change, current: store[change.id]) {
            case .save(let record): batch.saves.append(record)
            case .delete(let id): batch.deletes.append(id)
            case .nothing: nothing.append(change)
            }
        }
        engine.remove(nothing, zone: zone)
        return batch.isEmpty && !nothing.isEmpty ? nextBatch(zone: zone, pending: engine.pending(zone: zone)) : batch
    }

    func handle(_ event: SyncEvent) {
        switch event {
        case .fetched(_, let modifications, let deletions):
            apply(state.fetched(modifications: modifications, deletions: deletions))
        case .didFetch(_, let fromScratch):
            apply(state.didFetch(fromScratch: fromScratch))
        case .sent(_, let saved, let failed, let deleted):
            for record in saved { apply(state.saved(record)) }
            for id in deleted { apply(state.deleted(id)) }
            for (id, failure) in failed.sorted(by: { $0.key < $1.key }) { apply(state.failed(id, failure)) }
        }
    }

    private func apply(_ outcome: SyncOutcome) {
        for record in outcome.upserts { store[record.id, default: [:]].merge(record.fields) { $1 } }
        for id in outcome.deletions { store[id] = nil }
        lostEdits += outcome.lostEdits
        conflicts += outcome.conflicts
        engine.remove(outcome.remove, zone: Self.zone)
        engine.add(outcome.add, zone: Self.zone)
    }
}

private func item(_ n: Int) -> RecordID { RecordID(type: "Item", name: "i\(n)") }
private let zone = TestDevice.zone

// MARK: - The server

@MainActor
struct MemoryServerTests {
    let server: MemoryServer
    let id = RecordID(type: "Item", name: "i1")

    init() {
        server = MemoryServer()
        server.createZone(zone)
    }

    private func save(_ record: ServerRecord, atomic: Bool = false) throws -> (
        saved: [ServerRecord], failed: [RecordID: SaveFailure], deleted: [RecordID]
    ) {
        try server.modify(zone: zone, batch: SyncBatch(saves: [record], deletes: [], atomic: atomic))
    }

    @Test func aSaveWithAnOldTagIsRefusedWithTheServersRecord() throws {
        let first = try #require(try save(ServerRecord(id: id, tag: nil, fields: ["note": .string("one")])).saved.first)
        _ = try save(ServerRecord(id: id, tag: first.tag, fields: ["note": .string("two")]))
        let refused = try save(ServerRecord(id: id, tag: first.tag, fields: ["note": .string("stale")]))
        guard case .changed(let server) = refused.failed[id] else {
            Issue.record("not refused as changed")
            return
        }
        #expect(server.fields["note"] == .string("two"))
    }

    @Test func aNewRecordWhoseNameExistsIsRefused() throws {
        _ = try save(ServerRecord(id: id, tag: nil, fields: ["note": .string("one")]))
        guard case .changed = try save(ServerRecord(id: id, tag: nil, fields: ["note": .string("again")])).failed[id] else {
            Issue.record("not refused as changed")
            return
        }
    }

    @Test func aSaveOverADeletedRecordIsRefusedAndItStaysDeleted() throws {
        let first = try #require(try save(ServerRecord(id: id, tag: nil, fields: ["note": .string("one")])).saved.first)
        _ = try server.modify(zone: zone, batch: SyncBatch(saves: [], deletes: [id], atomic: false))
        #expect(try save(ServerRecord(id: id, tag: first.tag, fields: ["note": .string("late")])).failed[id] == .deleted)
        #expect(server.record(id, zone: zone) == nil)
        // A new record (no tag) with the same name is a new record.
        #expect(try save(ServerRecord(id: id, tag: nil, fields: ["note": .string("new")])).saved.count == 1)
    }

    @Test func savesKeepFieldsTheyDontSend() throws {
        let first = try #require(try save(ServerRecord(id: id, tag: nil, fields: ["note": .string("one"), "payee": .string("Shop")])).saved.first)
        _ = try save(ServerRecord(id: id, tag: first.tag, fields: ["note": .string("two")]))
        #expect(server.records(zone: zone)[id] == ["note": .string("two"), "payee": .string("Shop")])
    }

    @Test func deletingTwiceSucceeds() throws {
        _ = try save(ServerRecord(id: id, tag: nil, fields: [:]))
        for _ in 0..<2 {
            #expect(try server.modify(zone: zone, batch: SyncBatch(saves: [], deletes: [id], atomic: false)).deleted == [id])
        }
    }

    @Test func anAtomicBatchWithARefusedSaveSavesNothing() throws {
        let first = try #require(try save(ServerRecord(id: id, tag: nil, fields: ["note": .string("one")])).saved.first)
        _ = try save(ServerRecord(id: id, tag: first.tag, fields: ["note": .string("two")]))
        let other = RecordID(type: "Item", name: "i2")
        let result = try server.modify(
            zone: zone,
            batch: SyncBatch(
                saves: [ServerRecord(id: other, tag: nil, fields: [:]), ServerRecord(id: id, tag: first.tag, fields: ["note": .string("stale")])],
                deletes: [], atomic: true
            ))
        #expect(result.saved.isEmpty && result.failed[other] == .batchFailed)
        #expect(server.record(other, zone: zone) == nil)
    }

    @Test func changesComeInPagesWithDeletionsAndFromScratchOnlyWhatExists() throws {
        for n in 1...5 { _ = try save(ServerRecord(id: item(n), tag: nil, fields: [:])) }
        let start = try server.changes(zone: zone, since: nil, limit: 2)
        #expect(start.modifications.count == 2 && start.moreComing)
        _ = try server.modify(zone: zone, batch: SyncBatch(saves: [], deletes: [item(5)], atomic: false))
        let rest = try server.changes(zone: zone, since: start.token, limit: 10)
        #expect(rest.modifications.map(\.id) == [item(3), item(4)] && rest.deletions == [item(5)] && !rest.moreComing)
        let scratch = try server.changes(zone: zone, since: nil, limit: 10)
        #expect(scratch.modifications.count == 4 && scratch.deletions.isEmpty)
        server.expireTokens(zone: zone)
        #expect(throws: MemoryServer.Failure.tokenExpired) { try server.changes(zone: zone, since: rest.token, limit: 10) }
    }
}

// MARK: - Devices syncing

@MainActor
struct SyncScenarioTests {
    let server: MemoryServer
    let a: TestDevice
    let b: TestDevice

    init() {
        server = MemoryServer()
        server.createZone(zone)
        a = TestDevice(server)
        b = TestDevice(server)
    }

    private func settle(_ devices: [TestDevice]) async throws {
        for _ in 0..<3 { for d in devices { try await d.sync() } }
    }

    @Test func aNewRecordReachesTheOtherDevice() async throws {
        a.set(item(1), ["title": .string("Call Sam"), "sortOrder": .int(5)])
        try await settle([a, b])
        #expect(b.store[item(1)] == ["title": .string("Call Sam"), "sortOrder": .int(5)])
        #expect(a.engine.pending(zone: zone).isEmpty && b.state.pendingChanges.isEmpty)
    }

    @Test func editsToDifferentFieldsAreBothKept() async throws {
        a.set(item(1), ["title": .string("Call Sam"), "note": .string(""), "tag": .null])
        try await settle([a, b])
        a.set(item(1), ["note": .string("gift")])
        b.set(item(1), ["tag": .string("g1")])
        try await settle([a, b])
        #expect(a.store[item(1)] == b.store[item(1)])
        #expect(a.store[item(1)]?["note"] == .string("gift") && a.store[item(1)]?["tag"] == .string("g1"))
    }

    @Test func theLastEditToReachTheServerWins() async throws {
        a.set(item(1), ["note": .string("")])
        try await settle([a, b])
        a.set(item(1), ["note": .string("from A")])
        b.set(item(1), ["note": .string("from B")])
        try await a.engine.sendChanges()
        // B's save is refused (A's got there first), merged and sent again: B's reaches the server last.
        try await b.sync()
        try await a.sync()
        #expect(server.records(zone: zone)[item(1)]?["note"] == .string("from B"))
        #expect(a.store[item(1)]?["note"] == .string("from B") && b.store[item(1)]?["note"] == .string("from B"))
    }

    @Test func anEditLosesToADeleteAndOnlyItsDeviceSays() async throws {
        a.set(item(1), ["note": .string("")])
        try await settle([a, b])
        a.delete(item(1))
        try await a.sync()
        b.set(item(1), ["note": .string("late")])
        try await b.engine.sendChanges()
        #expect(b.store[item(1)] == nil && b.lostEdits.map(\.id) == [item(1)] && b.lostEdits.first?.fields == ["note"])
        #expect(a.lostEdits.isEmpty && server.record(item(1), zone: zone) == nil)
    }

    @Test func aDeleteArrivingBeforeAnEditIsSentLosesTheEdit() async throws {
        a.set(item(1), ["note": .string("")])
        try await settle([a, b])
        a.delete(item(1))
        try await a.sync()
        b.set(item(1), ["note": .string("unsent")])
        try await b.engine.fetchChanges()
        #expect(b.store[item(1)] == nil && b.lostEdits.count == 1 && b.engine.pending(zone: zone).isEmpty)
    }

    @Test func aRecordDeletedHereStaysDeletedWhateverArrives() async throws {
        a.set(item(1), ["note": .string("")])
        try await settle([a, b])
        a.delete(item(1))
        b.set(item(1), ["note": .string("edited elsewhere")])
        try await b.sync()
        try await a.engine.fetchChanges()
        #expect(a.store[item(1)] == nil)
        try await settle([a, b])
        #expect(a.store[item(1)] == nil && b.store[item(1)] == nil && server.record(item(1), zone: zone) == nil)
    }

    @Test func twoDevicesCreatingTheSameRecordShareIt() async throws {
        let rule = RecordID(type: "Context", name: "C0000000-0000-4000-8000-000000000002")
        a.set(rule, ["name": .string("Calls"), "createdAt": .int(1)])
        b.set(rule, ["name": .string("Phone calls")])
        try await a.sync()
        try await b.sync()
        try await a.sync()
        #expect(server.records(zone: zone).count == 1)
        #expect(a.store[rule] == b.store[rule] && a.store[rule]?["name"] == .string("Phone calls"))
        #expect(a.store[rule]?["createdAt"] == .int(1))
    }

    @Test func anAtomicGroupSavesWholeOrNotAtAll() async throws {
        let match = RecordID(type: "Project", name: "p1")
        for n in 1...2 { a.set(item(n), ["match": .null]) }
        try await settle([a, b])
        b.set(item(2), ["note": .string("B was here")])
        try await b.sync()
        a.group = { $0 == match || $0 == item(1) || $0 == item(2) ? "m1" : nil }
        a.set(match, ["origin": .string("manual")])
        a.set(item(1), ["match": .string("m1")])
        a.set(item(2), ["match": .string("m1")])
        // A's tag for i2 is old, so its first attempt is refused whole: nobody sees half the group.
        try await a.engine.sendChanges()
        try await b.engine.fetchChanges()
        let seen = [match, item(1), item(2)].map { b.store[$0]?["match"] ?? b.store[$0]?["origin"] }
        #expect(seen.allSatisfy { $0 == nil || $0 == .null } || seen.allSatisfy { $0 != nil && $0 != .null })
        try await settle([a, b])
        #expect(
            b.store[match]?["origin"] == .string("manual") && b.store[item(1)]?["match"] == .string("m1")
                && b.store[item(2)]?["match"] == .string("m1"))
        #expect(b.store[item(2)]?["note"] == .string("B was here"))
    }

    @Test func aFieldChangedWhileItWasBeingSentIsSentAgain() async throws {
        a.set(item(1), ["note": .string("one")])
        let change = try #require(a.engine.pending(zone: zone).first)
        guard case .save(let record) = a.state.outgoing(change, current: a.store[item(1)]) else {
            Issue.record("nothing to send")
            return
        }
        a.set(item(1), ["note": .string("two")])
        let result = try server.modify(zone: zone, batch: SyncBatch(saves: [record], deletes: [], atomic: false))
        a.handle(.sent(zone: zone, saved: result.saved, failed: result.failed, deleted: result.deleted))
        #expect(a.state[item(1)]?.pending["note"] != nil)
        try await a.sync()
        #expect(server.records(zone: zone)[item(1)]?["note"] == .string("two") && a.state.pendingChanges.isEmpty)
    }

    @Test func aRecordDeletedWhileItsFirstSaveIsOnItsWayStaysDeleted() async throws {
        a.set(item(1), ["note": .string("one")])
        let change = try #require(a.engine.pending(zone: zone).first)
        guard case .save(let record) = a.state.outgoing(change, current: a.store[item(1)]) else {
            Issue.record("nothing to send")
            return
        }
        a.delete(item(1))
        let result = try server.modify(zone: zone, batch: SyncBatch(saves: [record], deletes: [], atomic: false))
        a.handle(.sent(zone: zone, saved: result.saved, failed: result.failed, deleted: result.deleted))
        try await a.sync()
        #expect(server.records(zone: zone)[item(1)] == nil && a.store[item(1)] == nil && a.state.pendingChanges.isEmpty)
    }

    @Test func fetchesArriveInPages() async throws {
        b.engine.pageSize = 2
        for n in 1...5 { a.set(item(n), ["n": .int(n)]) }
        try await settle([a, b])
        #expect(b.store.count == 5)
    }

    @Test func afterAnExpiredTokenMissedDeletesAreFoundAndUnsentRecordsKept() async throws {
        for n in 1...3 { a.set(item(n), ["note": .string("")]) }
        try await settle([a, b])
        a.delete(item(1))
        a.delete(item(2))
        try await a.sync()
        server.expireTokens(zone: zone)
        b.set(item(2), ["note": .string("edited while behind")])
        b.engine.isOffline = true
        b.set(item(9), ["note": .string("new while behind")])
        b.engine.isOffline = false
        // In pages of one, so the fetch from scratch goes on with tokens of its own.
        b.engine.pageSize = 1
        try await b.engine.fetchChanges()
        #expect(b.store[item(1)] == nil && b.store[item(2)] == nil && b.store[item(3)] != nil)
        #expect(b.lostEdits.map(\.id) == [item(2)])
        #expect(b.store[item(9)] != nil)
        try await b.engine.sendChanges()
        #expect(server.record(item(9), zone: zone) != nil && server.record(item(2), zone: zone) == nil)
    }

    @Test func editsMadeOfflineGoWhenBackOnline() async throws {
        a.engine.isOffline = true
        a.set(item(1), ["note": .string("offline")])
        await #expect(throws: MemoryServer.Failure.offline) { try await a.sync() }
        a.engine.isOffline = false
        try await settle([a, b])
        #expect(b.store[item(1)]?["note"] == .string("offline"))
    }

    @Test func aDeleteCutShortCarriesOnAfterARelaunch() async throws {
        for n in 1...6 { a.set(item(n), ["note": .string("")]) }
        try await settle([a, b])
        for n in 1...6 { a.delete(item(n)) }
        a.batchLimit = 2
        a.engine.isOffline = false
        // One batch goes, then the device stops.
        let first = try #require(a.nextBatch(zone: zone, pending: a.engine.pending(zone: zone)))
        let result = try server.modify(zone: zone, batch: first)
        a.engine.remove(first.deletes.map { .delete($0) }, zone: zone)
        a.handle(.sent(zone: zone, saved: result.saved, failed: result.failed, deleted: result.deleted))
        a.engineState = try JSONEncoder().encode(MemorySyncEngine.State(tokens: [:], pending: [zone: a.engine.pending(zone: zone)]))
        try a.relaunch(server)
        try await settle([a, b])
        #expect(server.records(zone: zone).isEmpty && b.store.isEmpty)
    }

    @Test func syncStateSurvivesSaving() throws {
        a.set(item(1), ["note": .string("x"), "when": .date(Date(timeIntervalSinceReferenceDate: 12.345678))])
        let back = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(a.state))
        #expect(back.entries == a.state.entries && back.pendingChanges == a.state.pendingChanges)
    }

    @Test func savedEntriesComeBackAndOnlyChangedOnesAreReported() async throws {
        a.set(item(1), ["note": .string("x")])
        a.set(item(2), ["note": .string("y")])
        try await a.sync()
        var reloaded = SyncState(entries: a.state.entries)
        #expect(reloaded.takeChanged().isEmpty)
        _ = reloaded.recordLocal(item(2), values: ["note": .string("z")])
        #expect(reloaded.takeChanged() == [item(2)] && reloaded.takeChanged().isEmpty)
    }

    @Test func valuesCloudKitStoresDifferentlyArentChanges() async throws {
        a.set(item(1), ["paid": .bool(true), "tags": .strings([]), "memo": .string("")])
        try await a.sync()
        // As they come back from CloudKit: a boolean as an integer, empty values missing.
        _ = a.state.fetched(
            modifications: [ServerRecord(id: item(1), tag: a.state[item(1)]?.tag, fields: ["paid": .int(1), "tags": .null, "memo": .null])],
            deletions: [])
        #expect(a.state.recordLocal(item(1), values: ["paid": .bool(true), "tags": .strings([]), "memo": .string("")]).add.isEmpty)
    }

    // MARK: Conflicts

    @Test func aNoteChangedOnBothDevicesKeepsTheOtherVersion() async throws {
        a.set(item(1), ["body": .string("first")])
        try await settle([a, b])
        a.set(item(1), ["body": .string("from A")])
        b.set(item(1), ["body": .string("from B")])
        try await a.engine.sendChanges()
        try await b.sync()
        try await a.sync()
        #expect(server.records(zone: zone)[item(1)]?["body"] == .string("from B"))
        #expect(a.store[item(1)]?["body"] == .string("from B") && b.store[item(1)]?["body"] == .string("from B"))
        #expect(b.conflicts == [Conflict(id: item(1), field: "body", text: "from A")])
        #expect(a.conflicts.isEmpty)
    }

    @Test func aNoteChangedHereWhileAnotherVersionArrivesIsAConflictToo() async throws {
        a.set(item(1), ["body": .string("first")])
        try await settle([a, b])
        a.set(item(1), ["body": .string("from A")])
        try await a.sync()
        b.set(item(1), ["body": .string("from B")])
        try await b.engine.fetchChanges()
        #expect(b.conflicts == [Conflict(id: item(1), field: "body", text: "from A")])
        try await settle([a, b])
        #expect(a.store[item(1)]?["body"] == .string("from B"))
    }

    @Test func otherFieldsChangedOnBothDevicesArentConflicts() async throws {
        a.set(item(1), ["title": .string("first"), "body": .string("")])
        try await settle([a, b])
        a.set(item(1), ["title": .string("from A")])
        b.set(item(1), ["title": .string("from B")])
        try await a.sync()
        try await settle([b, a])
        #expect(a.conflicts.isEmpty && b.conflicts.isEmpty)
    }

    @Test func theSameNoteOnBothDevicesIsntAConflict() async throws {
        a.set(item(1), ["body": .string("first")])
        try await settle([a, b])
        a.set(item(1), ["body": .string("same")])
        b.set(item(1), ["body": .string("same")])
        try await a.engine.sendChanges()
        try await settle([b, a])
        #expect(a.conflicts.isEmpty && b.conflicts.isEmpty)
    }

    @Test func severalZonesShareOneEngine() async throws {
        server.createZone("other")
        final class Second: SyncEngineDelegate {
            var fetched: [RecordID] = []
            func nextBatch(zone: String, pending: [PendingChange]) -> SyncBatch? { nil }
            func handle(_ event: SyncEvent) {
                if case .fetched(_, let modifications, _) = event { fetched += modifications.map(\.id) }
            }
        }
        let second = Second()
        b.engine.attach(second, zone: "other")
        _ = try server.modify(zone: "other", batch: SyncBatch(saves: [ServerRecord(id: item(7), tag: nil, fields: [:])], deletes: [], atomic: false))
        a.set(item(1), ["note": .string("")])
        try await settle([a, b])
        #expect(second.fetched == [item(7)] && b.store.keys.sorted() == [item(1)])
    }
}
