import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// Decisions about tasks and making subtasks by dragging, each undone exactly.
@MainActor
struct DecisionsTests {
    static let today = LocalDate(2026, 10, 21)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
    }

    func project(_ title: String = "Kitchen") -> Item {
        context.insertProject(title)
    }

    func item(_ title: String, _ bucket: Bucket = .action, in project: Item? = nil) -> Item {
        let item = Item(title: title, bucket: bucket)
        context.insert(item)
        item.parent = project
        return item
    }

    // MARK: Projects

    @Test func aProjectGoesToSomedayAndBack() throws {
        let project = project()
        try context.save()
        let undo = try #require(Clarifier.moveToSomeday(project))
        #expect(project.bucket == .someday && !project.isActive)
        #expect(Clarifier.moveToSomeday(project) == nil, "no change")
        #expect(Clarifier.undo(undo, in: context))
        #expect(project.isActive)
        #expect(Clarifier.moveToSomeday(item("In the trash", .trash)) == nil)
    }

    @Test func aDroppedProjectKeepsItsItems() throws {
        let project = project()
        let action = item("Measure", in: project)
        try context.save()
        let undo = try #require(Clarifier.drop(project))
        #expect(project.status == .dropped && project.completedAt != nil && action.status == .open)
        #expect(!action.isListed(today: Self.today, doneSince: nil))
        Clarifier.undo(undo, in: context)
        #expect(project.isActive && project.completedAt == nil)
    }

    @Test func aDoneProjectMarksItsOpenItemsDone() {
        let project = project()
        let action = item("Measure", in: project)
        let waiting = item("Quote", .waiting, in: project)
        let step = item("Find the tape")
        step.parent = action
        project.markDone()
        #expect([action, waiting, step].allSatisfy { $0.status == .done })
        project.reopen()
        #expect([project, action, waiting, step].allSatisfy { $0.status == .open })
    }

    @Test func anItemIsHiddenAndShownAgain() throws {
        let project = project()
        let undo = try #require(Clarifier.hide(project, until: Self.today.adding(days: 3)))
        #expect(project.isHidden(today: Self.today))
        #expect(Clarifier.hide(project, until: Self.today.adding(days: 3)) == nil)
        Clarifier.undo(undo, in: context)
        #expect(project.hideUntil == nil)
    }

    @Test func undoingADeletedProjectDoesNothing() throws {
        let project = project()
        let undo = try #require(Clarifier.drop(project))
        context.delete(project)
        try context.save()
        #expect(!Clarifier.undo(undo, in: context))
    }

    @Test func aTaskGoesUnderAnotherButNeverUnderItsOwnOrTooDeep() {
        let project = project()
        let other = self.project("Garden")
        let action = item("Measure", in: project)
        let deep = item("Deep")
        var below = deep
        for _ in 0..<Item.deepestSubItem {
            let step = item("Step")
            step.parent = below
            below = step
        }
        #expect(Clarifier.canMake(other, aSubItemOf: project) && Clarifier.canMake(other, aSubItemOf: action))
        #expect(!Clarifier.canMake(project, aSubItemOf: action), "not under its own subtask")
        #expect(!Clarifier.canMake(deep, aSubItemOf: project), "its subtasks would go too deep")
    }

    @Test func placingRowsInATasksSubtasksTakesThemIn() throws {
        let project = project()
        let first = item("First", in: project)
        let loose = item("Loose")
        let step = item("Step")
        step.parent = first
        let placed = try #require(Clarifier.place([loose, step], among: [first], before: nil, in: project))
        #expect(!placed.separated && loose.parent === project && step.parent === project)
        Clarifier.undo(placed.undo, in: context)
        #expect(loose.parent == nil && step.parent === first)
        _ = Clarifier.place([step], among: [loose], before: loose)
        #expect(step.parent === first, "a list that isn't a task's subtasks leaves it under its task")
    }

    // MARK: Sub-items by dragging

    @Test func draggedItemsGoUnderTheirItemInOrderAndKeepTheirDetails() throws {
        let other = project("Garden")
        let parent = item("Paint the shed")
        let existing = try #require(NewRecord.subtask(of: parent, in: context))
        let first = item("Buy brushes", .inbox, in: other)
        let second = item("Sand the walls")
        try context.save()
        let undo = try #require(Clarifier.makeSubItems([first, second], of: parent))
        #expect(undo.title == "2 items")
        #expect(first.parent === parent && second.parent === parent)
        #expect(existing.sortOrder < first.sortOrder && first.sortOrder < second.sortOrder)
        #expect(first.bucket == .inbox && first.project === parent, "it keeps its own details")
        Clarifier.undo(undo, in: context)
        #expect(first.parent === other && second.parent == nil && existing.parent === parent)
    }

    @Test func subItemsNestButNeverUnderThemselves() throws {
        let parent = item("Paint the shed")
        let child = try #require(NewRecord.subtask(of: parent, in: context))
        let grandchild = try #require(NewRecord.subtask(of: child, in: context))
        let other = item("Wash the car")
        #expect(!Clarifier.canMake(parent, aSubItemOf: parent), "not under itself")
        #expect(!Clarifier.canMake(parent, aSubItemOf: grandchild), "not under its own sub-item")
        #expect(!Clarifier.canMake(child, aSubItemOf: parent), "already under it")
        #expect(Clarifier.canMake(other, aSubItemOf: child), "under a sub-item")
        #expect(Clarifier.canMake(parent, aSubItemOf: other), "with sub-items of its own")
        #expect(Clarifier.canMake(child, aSubItemOf: other), "from one item to another")
        #expect(Clarifier.makeSubItems([parent], of: grandchild) == nil)
        #expect(grandchild.depth == 2 && parent.subItemLevels == 2)
    }

    @Test func subItemsGoNoDeeperThanTheLimit() throws {
        var deepest = item("Top")
        for _ in 0..<Item.deepestSubItem { deepest = try #require(NewRecord.subtask(of: deepest, in: context)) }
        #expect(deepest.depth == Item.deepestSubItem)
        #expect(NewRecord.subtask(of: deepest, in: context) == nil)
        let withOneLevel = item("Two levels")
        _ = try #require(NewRecord.subtask(of: withOneLevel, in: context))
        #expect(!Clarifier.canMake(withOneLevel, aSubItemOf: try #require(deepest.parent)))
    }

    @Test func droppedBetweenSubItemsGoesThere() throws {
        let parent = item("Paint the shed")
        let first = try #require(NewRecord.subtask(of: parent, in: context))
        first.title = "Buy brushes"
        let second = try #require(NewRecord.subtask(of: parent, in: context))
        second.title = "Sand the walls"
        let loose = item("Choose a colour")
        try context.save()
        let undo = try #require(Clarifier.makeSubItems([loose], of: parent, before: second))
        let order = { (parent.children ?? []).sorted { $0.sortOrder < $1.sortOrder }.map(\.title) }
        #expect(order() == ["Buy brushes", "Choose a colour", "Sand the walls"])
        Clarifier.undo(undo, in: context)
        #expect(order() == ["Buy brushes", "Sand the walls"] && loose.parent == nil)
    }

    @Test func aSubItemMovesAmongItsItemsOwn() throws {
        let parent = item("Paint the shed")
        let first = try #require(NewRecord.subtask(of: parent, in: context))
        first.title = "Buy brushes"
        let second = try #require(NewRecord.subtask(of: parent, in: context))
        second.title = "Sand the walls"
        _ = try #require(Clarifier.makeSubItems([second], of: parent, before: first))
        #expect((parent.children ?? []).sorted { $0.sortOrder < $1.sortOrder }.map(\.title) == ["Sand the walls", "Buy brushes"])
        #expect(Clarifier.makeSubItems([first], of: parent, before: first) == nil, "before itself changes nothing")
    }

    @Test func rowsDroppedBetweenRowsGoBeforeTheNextItem() throws {
        let shed = item("Paint the shed")
        let brushes = try #require(NewRecord.subtask(of: shed, in: context))
        _ = try #require(NewRecord.subtask(of: shed, in: context))
        let car = item("Wash the car")
        let rows = ListRow.rows([shed, car, brushes], doneSince: nil)
        #expect(rows.map(\.item.id) == [shed.id, brushes.id, car.id])
        #expect(ListRow.nextItem(in: rows, at: 0) === shed)
        #expect(ListRow.nextItem(in: rows, at: 1) === car, "a nested row is skipped")
        #expect(ListRow.nextItem(in: rows, at: 3) == nil)
    }

    func list(_ titles: [String]) -> [Item] {
        titles.enumerated().map { index, title in
            let made = item(title)
            made.sortOrder = Double(index)
            return made
        }
    }

    @Test(
        arguments: [
            (["C"], "A", ["C", "A", "B"]),
            (["A"], nil, ["B", "C", "A"]),
            (["A"], "C", ["B", "A", "C"]),
            (["A", "C"], "B", ["A", "C", "B"]),
        ] as [([String], String?, [String])])
    func itemsArePlacedWhereTheyreDropped(moving: [String], before: String?, order: [String]) throws {
        let items = list(["A", "B", "C"])
        let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0) })
        let placed = try #require(
            Clarifier.place(moving.map { byTitle[$0]! }, among: items, before: before.map { byTitle[$0]! }))
        #expect(!placed.separated)
        #expect(items.sorted(by: Item.inListOrder).map(\.title) == order)
    }

    @Test func placingWhereItAlreadyIsChangesNothing() {
        let items = list(["A", "B", "C"])
        #expect(Clarifier.place([items[0]], among: items, before: items[1]) == nil)
        #expect(Clarifier.place([items[1]], among: items, before: items[1]) == nil)
    }

    @Test func aSubtaskPlacedAmongAListsItemsStaysUnderItsTask() throws {
        let items = list(["A", "B"])
        let child = item("Buy brushes")
        _ = Clarifier.makeSubItems([child], of: items[0])
        try context.save()
        let placed = try #require(Clarifier.place([child], among: items, before: items[1]))
        #expect(!placed.separated && child.parent === items[0])
        #expect((items + [child]).sorted(by: Item.inListOrder).map(\.title) == ["A", "Buy brushes", "B"])
        Clarifier.undo(placed.undo, in: context)
        #expect(child.parent === items[0])
        #expect(items.sorted(by: Item.inListOrder).map(\.title) == ["A", "B"])
    }

    @Test func newItemsGoAtTheTopAndNeverMovedOnesAreNewestFirst() {
        let older = item("Older")
        older.createdAt = Date(timeIntervalSince1970: 1_000_000)
        let newer = item("Newer")
        newer.createdAt = Date(timeIntervalSince1970: 2_000_000)
        let made = NewRecord.item(in: .action, in: context)
        made.title = "Made"
        #expect([older, made, newer].sorted(by: Item.inListOrder).map(\.title) == ["Made", "Newer", "Older"])
    }

}
