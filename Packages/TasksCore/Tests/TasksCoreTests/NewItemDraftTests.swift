import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// A new item is made only when its draft is saved with a title, where the draft was started.
@MainActor
struct NewItemDraftTests {
    let context: ModelContext

    init() throws {
        context = ModelContext(try TasksSchema.container(at: nil))
    }

    var items: [Item] { (try? context.fetch(FetchDescriptor<Item>())) ?? [] }

    @Test(arguments: ["", "   ", "\n", " \n "])
    func anEmptyDraftMakesNothing(title: String) {
        let draft = NewItemDraft(.list(bucket: .inbox, scheduled: nil, area: nil), title: title)
        #expect(draft.isEmpty)
        #expect(draft.make(in: context) == nil)
        #expect(items.isEmpty)
    }

    @Test(arguments: [
        (Bucket.inbox, nil as LocalDate?), (.action, nil), (.action, LocalDate(2026, 10, 28)), (.waiting, nil), (.someday, nil),
        (.reference, nil),
    ])
    func aListsDraftIsMadeAtItsTopWithItsTitle(bucket: Bucket, scheduled: LocalDate?) throws {
        let older = Item(title: "Older", bucket: bucket)
        context.insert(older)
        let made = try #require(NewItemDraft(.list(bucket: bucket, scheduled: scheduled, area: nil), title: "  Call the plumber ").make(in: context))
        #expect(made.item.title == "Call the plumber" && made.item.bucket == bucket)
        #expect(made.item.day(.scheduled) == scheduled)
        #expect(made.item.sortOrder < older.sortOrder, "at the top")
    }

    @Test func aDraftKeepsItsArea() throws {
        let home = Area(name: "Home")
        context.insert(home)
        let made = try #require(NewItemDraft(.list(bucket: .action, scheduled: nil, area: home.id), title: "Fix the gate").make(in: context))
        #expect(made.item.area === home)
    }

    @Test func aTitleIsKeptOnOneLine() throws {
        let made = try #require(NewItemDraft(.list(bucket: .inbox, scheduled: nil, area: nil), title: "Milk\nand eggs").make(in: context))
        #expect(made.item.title == "Milk and eggs")
    }

    @Test func aSubtaskIsMadeAtTheEndOfItsTasksWithItsDetails() throws {
        let task = Item(title: "Half marathon", bucket: .action)
        context.insert(task)
        task.dueDate = LocalDate(2026, 11, 30).storedDate
        let first = try #require(NewRecord.subtask(of: task, in: context))
        first.title = "Buy shoes"
        let draft = try #require(NewItemDraft.subtask(of: task))
        let made = try #require(NewItemDraft(draft.place, title: "Long run").make(in: context))
        #expect(made.item.parent === task && made.item.title == "Long run")
        #expect(made.item.sortOrder > first.sortOrder, "at the end")
        #expect(made.item.day(.due) == LocalDate(2026, 11, 30))
    }

    @Test func noSubtaskForATaskThatCantHaveOne() throws {
        let trashed = Item(title: "Old plan", bucket: .trash)
        context.insert(trashed)
        #expect(NewItemDraft.subtask(of: trashed) == nil)
        let gone = NewItemDraft(.subtask(of: UUID()), title: "Orphan")
        #expect(gone.make(in: context) == nil)
        #expect(items.count == 1)
    }

    @Test func undoingTakesTheMadeItemAway() throws {
        let made = try #require(NewItemDraft(.list(bucket: .inbox, scheduled: nil, area: nil), title: "Milk").make(in: context))
        #expect(items.count == 1)
        #expect(Clarifier.undo(made.undo, in: context))
        #expect(items.isEmpty)
    }
}
