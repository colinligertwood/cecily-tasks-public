import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// One device: a store on disk (change history needs one), sync, and an engine talking to a
/// shared `MemoryServer` in place of iCloud.
@MainActor
final class SyncedDevice {
    let folder: URL
    var container: ModelContainer
    let server: MemoryServer
    var engine: MemorySyncEngine
    var sync: TasksSync
    var engineState: Data?
    var lostEdits: [String] = []

    init(_ server: MemoryServer, before: ((ModelContext) throws -> Void)? = nil) throws {
        self.server = server
        folder = FileManager.default.temporaryDirectory.appending(path: "TasksSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        container = try TasksSchema.container(at: folder.appending(path: "Tasks.store"))
        let context = ModelContext(container)
        try TasksSchema.seed(context)
        if let before {
            try before(context)
            try context.save()
        }
        try TasksSync.begin(container: container)
        engine = MemorySyncEngine(server: server)
        sync = try TasksSync(container: container, engine: engine)
        attach()
        sync.recordEverything()
        sync.resume()
    }

    private func attach() {
        engine.attach(sync, zone: TasksSync.zoneName)
        engine.stateDidChange = { [weak self] in self?.engineState = $0 }
        sync.editsLost = { [weak self] in self?.lostEdits += $0 }
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Makes a change and saves it, as the app would.
    func edit(_ change: (ModelContext) throws -> Void) throws {
        let context = ModelContext(container)
        try change(context)
        try context.save()
        sync.captureLocalChanges()
    }

    func all<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func item(_ title: String) throws -> Item? {
        try all(Item.self).first { $0.title == title }
    }

    func sync() async throws {
        try await engine.sendChanges()
        try await engine.fetchChanges()
    }

    /// Quits and relaunches: the store, its sync state and the engine's state come back.
    func relaunch() throws {
        container = try TasksSchema.container(at: folder.appending(path: "Tasks.store"))
        engine = MemorySyncEngine(server: server, state: engineState)
        sync = try TasksSync(container: container, engine: engine)
        attach()
        sync.resume()
    }
}

@MainActor
struct TasksSyncTests {
    let server: MemoryServer
    let zone = TasksSync.zoneName

    init() {
        server = MemoryServer()
        server.createZone(TasksSync.zoneName)
    }

    private func settle(_ devices: [SyncedDevice]) async throws {
        for _ in 0..<3 { for device in devices { try await device.sync() } }
    }

    @Test func aSubtaskItsTaskAndAnAttachmentReachTheOtherDevice() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        let file = Data((0..<5000).map { UInt8($0 % 251) })
        try mac.edit { context in
            let project = context.insertProject("Kitchen refitted")
            project.body = "A **finished** kitchen"
            let item = Item(title: "Email Sam for the quote", bucket: .action)
            item.body = "- [ ] ask about worktops"
            item.dueDate = LocalDate(2026, 11, 6).storedDate
            let attachment = TasksCore.Attachment(filename: "plan.pdf", contentType: "com.adobe.pdf", data: file)
            context.insert(item)
            context.insert(attachment)
            item.parent = project
            attachment.item = item
        }
        try await settle([mac, phone])

        let item = try #require(try phone.item("Email Sam for the quote"))
        #expect(item.bucket == .action && item.body == "- [ ] ask about worktops")
        #expect(item.dueDate.map(LocalDate.init(day:)) == LocalDate(2026, 11, 6))
        #expect(item.project?.title == "Kitchen refitted" && item.project?.body == "A **finished** kitchen")
        #expect(item.attachments?.first?.filename == "plan.pdf" && item.attachments?.first?.data == file)
        #expect(item.attachments?.first?.byteSize == 5000)
        #expect(!mac.sync.hasPendingChanges && !phone.sync.hasPendingChanges)
    }

    @Test func contextsSubItemsAndRepeatsReachTheOtherDevice() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try await settle([mac, phone])
        try mac.edit { context in
            let calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
            let item = Item(title: "Pay the rent", bucket: .action)
            let child = Item(title: "Check the balance", bucket: .action)
            let repetition = Repetition()
            repetition.rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=1")), showDaysBefore: 3)
            context.insert(item)
            context.insert(child)
            context.insert(repetition)
            item.contexts = [calls]
            child.parent = item
            item.repeatRule = repetition
        }
        try await settle([mac, phone])
        let item = try #require(try phone.item("Pay the rent"))
        #expect(item.contexts?.map(\.name) == ["Calls"])
        #expect(item.children?.map(\.title) == ["Check the balance"])
        #expect(item.repeatRule?.rule == RepeatRule(.schedule(try Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=1")), showDaysBefore: 3))
    }

    @Test func editsMadeOfflineOnBothDevicesAreBothKept() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try mac.edit { $0.insert(Item(title: "Book the van")) }
        try await settle([mac, phone])

        mac.engine.isOffline = true
        phone.engine.isOffline = true
        try mac.edit { context in try #require(try context.fetch(FetchDescriptor<Item>()).first).bucket = .action }
        try phone.edit { context in
            try #require(try context.fetch(FetchDescriptor<Item>()).first).waitingOn = "Sam"
            context.insert(Item(title: "Added offline"))
        }
        await #expect(throws: MemoryServer.Failure.offline) { try await mac.sync() }
        mac.engine.isOffline = false
        phone.engine.isOffline = false
        try await settle([mac, phone])

        for device in [mac, phone] {
            let van = try #require(try device.item("Book the van"))
            #expect(van.bucket == .action && van.waitingOn == "Sam")
            #expect(try device.item("Added offline") != nil)
        }
    }

    @Test func aReviewStoppedOnOneDeviceIsResumedOnTheOtherAtTheSameList() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try mac.edit { context in
            WeeklyReview.tick(.agenda, in: context)
            WeeklyReview.tick(.inbox, in: context)
        }
        try await settle([mac, phone])

        let records = try phone.all(ReviewRecord.self)
        #expect(WeeklyReview.current(records) != nil)
        #expect(WeeklyReview.ticked(records) == [.agenda, .inbox])
        #expect(WeeklyReview.next(records) == .actions)
    }

    @Test func listsTickedOnBothDevicesOfflineAreAllKept() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try mac.edit { WeeklyReview.tick(.agenda, in: $0) }
        try await settle([mac, phone])

        mac.engine.isOffline = true
        phone.engine.isOffline = true
        try mac.edit { WeeklyReview.tick(.inbox, in: $0) }
        try phone.edit { context in
            WeeklyReview.tick(.waiting, in: context)
            WeeklyReview.tick(.someday, in: context)
        }
        mac.engine.isOffline = false
        phone.engine.isOffline = false
        try await settle([mac, phone])

        for device in [mac, phone] {
            let records = try device.all(ReviewRecord.self)
            #expect(records.count == 1)
            #expect(WeeklyReview.ticked(records) == [.agenda, .inbox, .waiting, .someday])
        }
        #expect(!mac.sync.hasPendingChanges && !phone.sync.hasPendingChanges)
    }

    @Test func reviewsStartedOnBothDevicesOfflineBecomeOne() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        mac.engine.isOffline = true
        phone.engine.isOffline = true
        try mac.edit { WeeklyReview.tick(.agenda, in: $0, at: Date(timeIntervalSinceNow: -60)) }
        try phone.edit { WeeklyReview.tick(.actions, in: $0) }
        mac.engine.isOffline = false
        phone.engine.isOffline = false
        try await settle([mac, phone])

        #expect(WeeklyReview.ticked(try phone.all(ReviewRecord.self)) == [.agenda, .actions])
        try phone.edit { WeeklyReview.finish(in: $0) }
        try await settle([mac, phone])

        for device in [mac, phone] {
            let records = try device.all(ReviewRecord.self)
            #expect(records.count == 1)
            #expect(WeeklyReview.current(records) == nil)
            #expect(Set(records.first?.stepsDone ?? []) == ["agenda", "actions"])
        }
    }

    @Test func aNoteChangedOnBothDevicesKeepsTheOtherVersionAsACopy() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try mac.edit { context in
            let item = Item(title: "Plan the party")
            item.body = "Guests: 10"
            context.insert(item)
        }
        try await settle([mac, phone])

        mac.engine.isOffline = true
        phone.engine.isOffline = true
        try mac.edit { context in try #require(try context.fetch(FetchDescriptor<Item>()).first).body = "Guests: 12, from the Mac" }
        try phone.edit { context in try #require(try context.fetch(FetchDescriptor<Item>()).first).body = "Guests: 15, from the phone" }
        mac.engine.isOffline = false
        phone.engine.isOffline = false
        // The Mac's change reaches iCloud first; the phone's reaches it last, so it's the one kept.
        try await mac.sync()
        try await settle([phone, mac])

        #expect(try mac.item("Plan the party")?.body == "Guests: 15, from the phone")
        #expect(try phone.item("Plan the party")?.body == "Guests: 15, from the phone")
        let copies = try phone.all(ConflictedCopy.self)
        #expect(copies.map(\.text) == ["Guests: 12, from the Mac"])
        #expect(copies.first?.field == "body" && copies.first?.recordType == "Item")
        #expect(try mac.all(ConflictedCopy.self).isEmpty)
    }

    @Test func aDeleteReachesTheOtherDeviceWithWhatWentWithIt() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try mac.edit { context in
            let item = Item(title: "Scan the receipts")
            let attachment = TasksCore.Attachment(filename: "receipt.jpg", contentType: "public.jpeg", data: Data([9, 9, 9]))
            context.insert(item)
            context.insert(attachment)
            attachment.item = item
        }
        try await settle([mac, phone])
        #expect(try phone.all(TasksCore.Attachment.self).count == 1)

        try phone.edit { context in
            for item in try context.fetch(FetchDescriptor<Item>()) { context.delete(item) }
        }
        try await settle([phone, mac])
        #expect(try mac.all(Item.self).isEmpty)
        #expect(try mac.all(TasksCore.Attachment.self).isEmpty)
        #expect(server.records(zone: zone).keys.allSatisfy { $0.type != "Item" && $0.type != "Attachment" })
    }

    @Test func anEditToSomethingDeletedElsewhereIsReported() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try mac.edit { $0.insert(Item(title: "Return the parcel")) }
        try await settle([mac, phone])
        try mac.edit { context in
            for item in try context.fetch(FetchDescriptor<Item>()) { context.delete(item) }
        }
        try await mac.sync()
        try phone.edit { context in try #require(try context.fetch(FetchDescriptor<Item>()).first).body = "too late" }
        try await phone.sync()
        #expect(phone.lostEdits == ["The item “Return the parcel”"])
        #expect(try phone.all(Item.self).isEmpty)
    }

    @Test func aNewDeviceTakesTheBuiltInsAlreadyInICloud() async throws {
        let mac = try SyncedDevice(server)
        try await mac.sync()
        try await mac.sync()
        try mac.edit { context in
            let calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
            calls.name = "Phone calls"
            calls.modifiedAt = .now
            let settings = try #require(try context.fetch(FetchDescriptor<AppSettings>()).first)
            settings.dueNotificationTime = 8 * 60
            settings.modifiedAt = .now
        }
        try await mac.sync()

        let phone = try SyncedDevice(server)
        try await settle([phone, mac])
        let names = try phone.all(Context.self).map(\.name).sorted()
        #expect(names == ["Errands", "Meetings", "Phone calls"])
        #expect(try phone.all(AppSettings.self).map(\.dueNotificationTime) == [8 * 60])
        #expect(try mac.all(Context.self).count == Context.builtIn.count)
        #expect(server.records(zone: zone).keys.filter { $0.type == "Context" }.count == Context.builtIn.count)
    }

    @Test func twoDevicesStartingTogetherShareOneSetOfBuiltIns() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try await settle([mac, phone])
        #expect(server.records(zone: zone).keys.filter { $0.type == "Context" }.count == Context.builtIn.count)
        #expect(server.records(zone: zone).keys.filter { $0.type == "AppSettings" }.count == 1)
        #expect(try mac.all(Context.self).count == Context.builtIn.count)
        #expect(try phone.all(Context.self).count == Context.builtIn.count)
    }

    @Test func whatWasInTheStoreBeforeSyncIsSent() async throws {
        let mac = try SyncedDevice(server) { context in
            context.insert(Item(title: "Made before sync"))
        }
        let phone = try SyncedDevice(server)
        try await settle([mac, phone])
        #expect(try phone.item("Made before sync") != nil)
    }

    @Test func anEditSavedAnywhereIsPickedUpWithoutBeingAsked() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try await settle([mac, phone])
        let context = ModelContext(mac.container)
        context.insert(Item(title: "Saved by a page"))
        try context.save()
        // Read shortly after the save; the main actor may be busy with other tests meanwhile.
        for _ in 0..<50 where mac.sync.pendingCount == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(mac.sync.pendingCount == 1)
        try await settle([mac, phone])
        #expect(try phone.item("Saved by a page") != nil)
    }

    @Test func capturesAndClarifyDecisionsReachTheOtherDevice() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try await settle([mac, phone])
        try mac.edit { context in
            context.insertProject("Kitchen refit", withSubtask: true)
            try context.save()
            Capture.add(
                "Ask about worktops #kitchen-refit @calls due:fri\nWater the plants every weekday\nBathroom", source: .quickAdd,
                today: LocalDate(2026, 10, 20), in: context)
        }
        try await settle([mac, phone])
        let worktops = try #require(try phone.item("Ask about worktops"))
        #expect(worktops.bucket == .inbox && worktops.project?.title == "Kitchen refit" && worktops.contexts?.map(\.name) == ["Calls"])
        #expect(try phone.item("Water the plants")?.repeatRule?.naturalText == "every weekday")

        try phone.edit { context in
            let bathroom = try #require(try context.fetch(FetchDescriptor<Item>()).first { $0.title == "Bathroom" })
            var outcome = ClarifyOutcome(.waiting(person: "Alex", followUp: LocalDate(2026, 10, 27)))
            outcome.title = "Measure the bathroom"
            outcome.project = .new(title: "New bathroom fitted", moreActions: ["Choose tiles"])
            Clarifier.file(bathroom, outcome, today: LocalDate(2026, 10, 20))
        }
        try await settle([phone, mac])
        let measure = try #require(try mac.item("Measure the bathroom"))
        #expect(measure.bucket == .waiting && measure.waitingOn == "Alex" && measure.project?.title == "New bathroom fitted")
        #expect(try mac.item("Choose tiles")?.project?.title == "New bathroom fitted")
        #expect(try mac.item("Bathroom") == nil)
    }

    @Test func editsWaitingToGoSurviveARelaunch() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try await settle([mac, phone])
        mac.engine.isOffline = true
        try mac.edit { $0.insert(Item(title: "Written on the train")) }
        try mac.relaunch()
        try await settle([mac, phone])
        #expect(try phone.item("Written on the train") != nil)
    }

    @Test func aReferenceToSomethingNotYetArrivedIsLinkedWhenItDoes() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try mac.edit { context in
            let project = context.insertProject("Garden")
            for n in 1...4 {
                let item = Item(title: "Step \(n)", bucket: .action)
                context.insert(item)
                item.parent = project
            }
        }
        try await mac.sync()
        // Pages of one record, so items can arrive before their project.
        phone.engine.pageSize = 1
        try await settle([phone, mac])
        let items = try phone.all(Item.self).filter { !$0.isProject }
        #expect(items.count == 4 && items.allSatisfy { $0.project?.title == "Garden" })
        #expect(!phone.sync.hasPendingChanges)
    }

    @Test func recordsWithFieldsAndTypesNoLongerInTheModelAreReadWithoutThem() async throws {
        let goal = UUID()
        let item = UUID()
        _ = try server.modify(
            zone: zone,
            batch: SyncBatch(
                saves: [
                    ServerRecord(id: RecordID(type: "Goal", name: goal.uuidString), tag: nil, fields: ["title": .string("Run a half marathon")]),
                    ServerRecord(
                        id: RecordID(type: "Item", name: item.uuidString), tag: nil,
                        fields: [
                            "title": .string("Book a physio"), "bucketRaw": .string(Bucket.action.rawValue),
                            "tags": .strings(["health"]), "goal": .uuid(goal),
                        ]),
                    ServerRecord(
                        id: RecordID(type: "Area", name: UUID().uuidString), tag: nil,
                        fields: ["name": .string("Health"), "notes": .string("Knee rehab")]),
                ], deletes: [], atomic: false))
        let phone = try SyncedDevice(server)
        try await settle([phone])
        let arrived = try #require(try phone.item("Book a physio"))
        #expect(arrived.id == item && arrived.bucket == .action)
        #expect(try phone.all(Area.self).map(\.name) == ["Health"])
        #expect(phone.lostEdits.isEmpty && !phone.sync.hasPendingChanges)
    }

    @Test func emptyingTheTrashDeletesItAndItsSubtasksOnTheOtherDevice() async throws {
        let mac = try SyncedDevice(server)
        let phone = try SyncedDevice(server)
        try mac.edit { context in
            let fence = context.insertProject("Repaint the fence")
            let paint = Item(title: "Buy fence paint", bucket: .action)
            context.insert(paint)
            paint.parent = fence
            context.insert(Item(title: "Book the boiler service", bucket: .action))
            Clarifier.file(fence, ClarifyOutcome(.trash), today: LocalDate(2026, 10, 26))
        }
        try await settle([mac, phone])
        #expect(try phone.item("Repaint the fence")?.trashedFrom == .action)
        try mac.edit { context in TrashList.empty(in: context) }
        try await settle([mac, phone])
        #expect(try phone.all(Item.self).map(\.title) == ["Book the boiler service"])
    }
}
