import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct ExportTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    static let now = LocalDate(2026, 10, 21).date(in: calendar, hour: 10, minute: 30)

    let context: ModelContext
    let folder: URL

    init() throws {
        context = ModelContext(try TasksSchema.container(at: nil))
        try Self.fill(context)
        folder = FileManager.default.temporaryDirectory.appending(path: "ExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A record of every type: an area with a task, its subtask and a repeating action, a note
    /// with an attachment, a context of its own, and a finished review.
    static func fill(_ context: ModelContext) throws {
        try TasksSchema.seed(context)
        let home = Area(name: "Home")
        let garden = Context(name: "Garden", symbol: "leaf")
        let fence = Item(title: "Fence painted", bucket: .action)
        fence.area = home
        fence.body = "Green, *two* coats."
        fence.dueDate = LocalDate(2026, 11, 2).storedDate
        let sand = Item(title: "Sand the fence", bucket: .action)
        sand.parent = fence
        sand.contexts = [garden]
        let bins = Item(title: "Put the bins out", bucket: .action)
        let repetition = Repetition()
        repetition.rule = RepeatRule(.schedule(Recurrence(.weekly, byDay: [.init(.tuesday)])))
        bins.repeatRule = repetition
        let note = Item(title: "Paint colours", bucket: .reference)
        note.kind = .note
        let swatch = Attachment(filename: "swatch.png", contentType: "public.png", data: TestFiles.image(width: 40, height: 30))
        swatch.item = note
        let review = ReviewRecord()
        review.startedAt = now.addingTimeInterval(-86400)
        review.completedAt = review.startedAt.addingTimeInterval(1800)
        review.stepsDone = ReviewList.allCases.map(\.rawValue)
        for model in [home, garden, fence, sand, bins, repetition, note, swatch, review] as [any PersistentModel] {
            context.insert(model)
        }
        try context.save()
    }

    func emptyStore() throws -> ModelContext {
        let empty = ModelContext(try TasksSchema.container(at: nil))
        try TasksSchema.seed(empty)
        try empty.save()
        return empty
    }

    /// Every synced record in `context`, by type and record name, with its synced values.
    func records(_ context: ModelContext) throws -> [String: [String: SyncValue]] {
        var all: [String: [String: SyncValue]] = [:]
        for type in SyncModels.all { try collect(type, context, into: &all) }
        return all
    }

    private func collect<T: SyncModel>(_ type: T.Type, _ context: ModelContext, into all: inout [String: [String: SyncValue]]) throws {
        for object in try context.fetch(FetchDescriptor<T>()) {
            all["\(T.recordType)/\(object.recordName)"] = object.syncFields()
        }
    }

    @Test func aFullExportRestoresWithNothingLost() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FullExport.write(context, to: folder, now: Self.now, calendar: Self.calendar)
        let restored = try emptyStore()
        try FullExport.restore(from: folder, into: restored)

        let before = try records(context)
        let after = try records(restored)
        #expect(after.keys.sorted() == before.keys.sorted())
        for (key, fields) in before {
            #expect(after[key] == fields, "\(key)")
        }
        #expect(try restored.fetchCount(FetchDescriptor<Item>()) == context.fetchCount(FetchDescriptor<Item>()))
        let attachments = try restored.fetch(FetchDescriptor<TasksCore.Attachment>())
        #expect(!attachments.isEmpty)
        #expect(attachments.allSatisfy { $0.data != nil && $0.item != nil })
        #expect(try restored.fetch(FetchDescriptor<Repetition>()).allSatisfy { $0.item != nil })
    }

    @Test func everySyncedFieldIsExported() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FullExport.write(context, to: folder, now: Self.now, calendar: Self.calendar)
        let contents = try FullExport.read(folder)
        #expect(contents.version == FullExport.formatVersion)
        for record in contents.records {
            let names = SyncModels.fieldNames[record.type] ?? []
            let assets = SyncModels.assets[record.type] ?? []
            #expect(Set(record.fields.keys) == Set(names).subtracting(assets), "\(record.type)")
            #expect(Set(record.files.keys).isSubset(of: assets))
        }
        #expect(Set(contents.records.map(\.type)) == Set(SyncModels.all.map { $0.recordType }))
    }

    @Test func attachmentsAreFilesByTheirNames() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FullExport.write(context, to: folder, now: Self.now, calendar: Self.calendar)
        for attachment in try context.fetch(FetchDescriptor<TasksCore.Attachment>()) {
            let url = folder.appending(path: "Attachments/\(attachment.recordName)/\(FullExport.safeFilename(attachment.filename))")
            #expect(try Data(contentsOf: url) == attachment.data)
        }
    }

    @Test func listsAndAreasAreMarkdownFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FullExport.write(context, to: folder, now: Self.now, calendar: Self.calendar)
        for name in ["Inbox", "Actions", "Waiting", "Someday", "Reference"] {
            let text = try String(contentsOf: folder.appending(path: "\(name).md"), encoding: .utf8)
            #expect(text.hasPrefix("# \(name)\n"))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Trash.md").path))
        for area in try context.fetch(FetchDescriptor<Area>()) {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Areas/\(MarkdownExport.filename(for: area.name))").path))
        }
    }

    @Test func restoringIsRefusedWhenThereAreItems() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FullExport.write(context, to: folder, now: Self.now, calendar: Self.calendar)
        let count = try context.fetchCount(FetchDescriptor<Item>())
        #expect(throws: FullExport.Failure.storeNotEmpty) { try FullExport.restore(from: folder, into: context) }
        #expect(try context.fetchCount(FetchDescriptor<Item>()) == count)
    }

    @Test func aFolderThatIsntAnExportIsRefused() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: FullExport.Failure.notAnExport) { try FullExport.restore(from: folder, into: try emptyStore()) }
    }

    @Test func anItemAsMarkdown() throws {
        let area = Area(name: "Home")
        let item = Item(title: "Paint the fence", bucket: .action)
        item.area = area
        item.dueDate = LocalDate(2026, 11, 2).storedDate
        item.body = "Buy *green* paint."
        context.insert(area)
        context.insert(item)
        for (index, title) in ["Sand it", "First coat"].enumerated() {
            let child = Item(title: title, bucket: .action)
            child.sortOrder = Double(index)
            child.parent = item
            context.insert(child)
        }
        item.children?.first { $0.title == "Sand it" }?.markDone(at: Self.now)

        #expect(
            MarkdownExport.markdown(for: item, calendar: Self.calendar) == """
                # Paint the fence

                - Area: Home
                - Due: 2026-11-02

                - [x] Sand it
                - [ ] First coat

                Buy *green* paint.
                """)
        #expect(MarkdownExport.openSubtasks(of: item) == "- [ ] First coat")
    }

    @Test(arguments: [("Plans/2027", "Plans-2027.md"), ("", "Untitled.md"), (".hidden", "file.hidden.md"), ("Home", "Home.md")])
    func fileNames(_ title: String, _ expected: String) {
        #expect(MarkdownExport.filename(for: title) == expected)
    }
}
