import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// Subtasks start with a copy of their task's details, are listed by themselves, and are done
/// and opened again with it.
@MainActor
struct SubItemTests {
    static let today = LocalDate(2026, 10, 21)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        try TasksSchema.seed(context)
    }

    func item(_ title: String, _ bucket: Bucket = .action, createdAt: Date = .now) -> Item {
        let item = Item(title: title, bucket: bucket)
        item.createdAt = createdAt
        context.insert(item)
        return item
    }

    func subItem(of parent: Item, _ title: String) throws -> Item {
        let made = try #require(NewRecord.subtask(of: parent, in: context))
        made.title = title
        return made
    }

    // MARK: Making them

    @Test func subItemsAreMadeInOrder() throws {
        let parent = item("Paint the shed")
        let first = try subItem(of: parent, "Buy brushes")
        let second = try subItem(of: parent, "Sand the walls")
        #expect(first.parent === parent && second.parent === parent)
        #expect(first.sortOrder < second.sortOrder)
    }

    @Test func doneAndReopeningReachEveryLevel() throws {
        let top = item("Refit the kitchen")
        let middle = try subItem(of: top, "Order tiles")
        let bottom = try subItem(of: middle, "Choose a colour")
        top.markDone()
        #expect([middle, bottom].allSatisfy { $0.status == .done })
        top.reopen()
        #expect([top, middle, bottom].allSatisfy { $0.status == .open })
        top.markDone()
        bottom.reopen()
        #expect([top, middle, bottom].allSatisfy { $0.status == .open })
    }

    @Test(arguments: [Bucket.inbox, .action, .waiting, .someday, .reference])
    func aSubtaskStartsWithACopyOfItsTasksDetails(bucket: Bucket) throws {
        let parent = item("Paint the shed", bucket)
        let area = Area(name: "Home")
        context.insert(area)
        let calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
        parent.area = area
        parent.contexts = [calls]
        parent.scheduledDate = Self.today.storedDate
        parent.scheduledTime = Self.today.date(in: .current, hour: 9)
        parent.dueDate = Self.today.adding(days: 3).storedDate
        parent.timeEstimate = .oneHour
        parent.energy = .high
        parent.waitingOn = "Sam"
        parent.followUpDate = Self.today.adding(days: 2).storedDate
        parent.hideUntil = Self.today.adding(days: 1).storedDate
        parent.body = "Notes"
        parent.isSequential = true
        let child = try subItem(of: parent, "Buy brushes")
        let expected = bucket == .reference ? Bucket.action : bucket
        #expect(child.bucket == expected && child.area === area && child.contexts?.map(\.name) == ["Calls"])
        #expect(child.scheduledDate == parent.scheduledDate && child.scheduledTime == parent.scheduledTime && child.dueDate == parent.dueDate)
        #expect(child.timeEstimate == .oneHour && child.energy == .high && child.waitingOn == "Sam" && child.followUpDate == parent.followUpDate)
        #expect(child.hideUntil == nil && child.body.isEmpty && !child.isSequential && child.repeatRule == nil, "not copied")
        #expect(child.editableFields == ItemField.fields(for: expected))
        parent.area = nil
        #expect(child.area === area, "a copy, not kept in step")
    }

    @Test func aSubtaskOfAReferenceNoteIsInActionsAndTheNoteIsntStalled() throws {
        let meeting = item("1:1 with Noor", .reference)
        meeting.kind = .note
        let raised = try subItem(of: meeting, "Training budget")
        #expect(raised.isInActions(today: Self.today) && raised.kind == .action)
        raised.markDone()
        #expect(meeting.status == .open && !meeting.isStalled(today: Self.today) && !meeting.isInActions(today: Self.today))
    }

    @Test func aTaskInTheTrashGetsNoSubtasks() {
        #expect(NewRecord.subtask(of: item("Trashed", .trash), in: context) == nil)
    }

    @Test func aTaskWithAnOpenSubtaskIsntInActionsButTheSubtaskIs() throws {
        let parent = item("Paint the shed")
        let child = try subItem(of: parent, "Buy brushes")
        #expect(!parent.isInActions(today: Self.today) && child.isInActions(today: Self.today))
        child.markDone()
        #expect(parent.isInActions(today: Self.today) && parent.isStalled(today: Self.today), "with none left it's in Actions, stalled")
    }

    // MARK: Done

    @Test func doneTakesTheOpenSubItemsWithIt() throws {
        let parent = item("Paint the shed")
        let open = try subItem(of: parent, "Buy brushes")
        let earlier = try subItem(of: parent, "Choose a colour")
        let before = Date(timeIntervalSince1970: 1_000_000)
        earlier.markDone(at: before)
        let now = Date(timeIntervalSince1970: 2_000_000)
        parent.markDone(at: now)
        #expect(parent.status == .done && parent.completedAt == now)
        #expect(open.status == .done && open.completedAt == now)
        #expect(earlier.completedAt == before, "a sub-item already done keeps when it was done")
        #expect(parent.bucket == .action, "done doesn't move an item")
    }

    @Test func reopeningBringsBackTheSubItemsDoneWithIt() throws {
        let parent = item("Paint the shed", .inbox)
        let open = try subItem(of: parent, "Buy brushes")
        let earlier = try subItem(of: parent, "Choose a colour")
        earlier.markDone(at: Date(timeIntervalSince1970: 1_000_000))
        parent.markDone(at: Date(timeIntervalSince1970: 2_000_000))
        parent.reopen()
        #expect(parent.status == .open && parent.completedAt == nil && parent.bucket == .inbox)
        #expect(open.status == .open && open.completedAt == nil)
        #expect(earlier.status == .done)
    }

    @Test func reopeningASubItemReopensItsItem() throws {
        let parent = item("Paint the shed")
        let first = try subItem(of: parent, "Buy brushes")
        let second = try subItem(of: parent, "Sand the walls")
        parent.markDone()
        first.reopen()
        #expect(first.status == .open && parent.status == .open)
        #expect(second.status == .done, "only the one reopened")
    }

    @Test func doneAndReopenSetModifiedAt() {
        let item = item("Call the bank")
        item.modifiedAt = .distantPast
        let now = Date(timeIntervalSince1970: 2_000_000)
        item.markDone(at: now)
        #expect(item.modifiedAt == now)
        item.markDone(at: now.addingTimeInterval(60))
        #expect(item.modifiedAt == now && item.completedAt == now, "marking a done item done changes nothing")
        item.reopen(at: now.addingTimeInterval(120))
        #expect(item.modifiedAt == now.addingTimeInterval(120))
    }

    // MARK: Rows

    @Test func aSubtaskIsNestedUnderItsTaskWhenBothAreListed() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let shed = item("Paint the shed", createdAt: start)
        let car = item("Wash the car", createdAt: start.addingTimeInterval(60))
        let sand = try subItem(of: shed, "Sand the walls")
        let brushes = try subItem(of: shed, "Buy brushes")
        brushes.sortOrder = -1
        let soft = try subItem(of: brushes, "Soft ones")
        let rows = ListRow.rows([sand, car, soft, shed, brushes], doneSince: nil)
        #expect(rows.map(\.item.title) == ["Wash the car", "Paint the shed", "Buy brushes", "Soft ones", "Sand the walls"])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 1])
        #expect(rows.map(\.isUnderParent) == [false, false, true, true, true])
        #expect(rows.map { $0.under?.title } == [nil, nil, "Paint the shed", "Buy brushes", "Paint the shed"])
    }

    @Test func aFilterKeepsTopRowsWithEverythingNestedUnderThem() throws {
        let shed = item("Paint the shed")
        let brushes = try subItem(of: shed, "Buy brushes")
        let soft = try subItem(of: brushes, "Soft ones")
        let car = item("Wash the car")
        let sponge = try subItem(of: car, "Buy a sponge")
        let rows = ListRow.rows([shed, brushes, soft, car, sponge], doneSince: nil) { $0.title != "Wash the car" && $0.title != "Buy brushes" }
        #expect(rows.map(\.item.title) == ["Paint the shed", "Buy brushes", "Soft ones"], "only the top rows are filtered")
        let alone = ListRow.rows([brushes, sponge], doneSince: nil) { $0.title != "Buy a sponge" }
        #expect(alone.map(\.item.title) == ["Buy brushes"], "a subtask at the top is filtered itself")
    }

    @Test func aSubtaskWhoseTaskIsntListedIsByItself() throws {
        let shed = item("Paint the shed")
        let brushes = try subItem(of: shed, "Buy brushes")
        let soft = try subItem(of: brushes, "Soft ones")
        #expect(ListRow.rows([brushes], doneSince: nil).map(\.depth) == [0])
        let skipping = ListRow.rows([shed, soft], doneSince: nil)
        #expect(
            skipping.map(\.depth) == [0, 1] && skipping.map(\.isUnderParent) == [false, false], "under its task's task, it keeps its Project tag")
    }

    @Test func theCountIsDoneOfAllButTrashedAndDropped() throws {
        let shed = item("Paint the shed")
        #expect(shed.subItemCount == nil)
        try subItem(of: shed, "Buy brushes").markDone()
        _ = try subItem(of: shed, "Sand the walls")
        try subItem(of: shed, "Ask about a ladder").bucket = .trash
        try subItem(of: shed, "Hire a sprayer").status = .dropped
        let brushes = try #require(shed.children?.first { $0.title == "Buy brushes" })
        _ = try subItem(of: brushes, "Soft ones")
        #expect(shed.subItemCount.map { [$0.done, $0.total] } == [1, 2])
    }
}
