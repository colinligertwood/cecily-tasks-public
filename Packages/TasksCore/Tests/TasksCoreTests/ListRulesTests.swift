import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct ListRulesTests {
    static let today = LocalDate(2026, 10, 21)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
    }

    /// Where a project is: active, on Someday, done, dropped or in the trash.
    enum ProjectState: CaseIterable, Sendable {
        case active, someday, done, dropped, trash
    }

    func project(_ title: String, _ state: ProjectState = .active) -> Item {
        let project = Item(title: title, bucket: .action)
        switch state {
        case .active: break
        case .someday: project.bucket = .someday
        case .done: project.status = .done
        case .dropped: project.status = .dropped
        case .trash: project.bucket = .trash
        }
        context.insert(project)
        return project
    }

    /// An item in a stalled-detection case: where it is, whether it's open, and the day it's
    /// scheduled for, in days from today.
    struct Piece: Sendable {
        var bucket: Bucket
        var status: ItemStatus = .open
        var scheduledIn: Int?
        var hiddenFor: Int?
        var isSubItem = false
    }

    struct StalledCase: CustomTestStringConvertible, Sendable {
        let label: String
        var status: ProjectState = .active
        let pieces: [Piece]
        let isStalled: Bool
        var testDescription: String { label }
    }

    // Each answer is worked out by hand from the rule for a stalled task.
    @Test(arguments: [
        StalledCase(label: "no subtasks", pieces: [], isStalled: false),
        StalledCase(label: "only done actions", pieces: [Piece(bucket: .action, status: .done)], isStalled: true),
        StalledCase(label: "only dropped actions", pieces: [Piece(bucket: .action, status: .dropped)], isStalled: false),
        StalledCase(label: "an open action", pieces: [Piece(bucket: .action)], isStalled: false),
        StalledCase(label: "only an open waiting item", pieces: [Piece(bucket: .waiting)], isStalled: false),
        StalledCase(label: "only a done waiting item", pieces: [Piece(bucket: .waiting, status: .done)], isStalled: true),
        StalledCase(label: "only someday items", pieces: [Piece(bucket: .someday)], isStalled: true),
        StalledCase(label: "only reference and trash", pieces: [Piece(bucket: .reference), Piece(bucket: .trash)], isStalled: true),
        StalledCase(label: "only an inbox item", pieces: [Piece(bucket: .inbox)], isStalled: true),
        StalledCase(label: "an inbox item scheduled tomorrow", pieces: [Piece(bucket: .inbox, scheduledIn: 1)], isStalled: false),
        StalledCase(label: "an inbox item scheduled today", pieces: [Piece(bucket: .inbox, scheduledIn: 0)], isStalled: true),
        StalledCase(label: "an inbox item scheduled yesterday", pieces: [Piece(bucket: .inbox, scheduledIn: -1)], isStalled: true),
        StalledCase(label: "a done item scheduled tomorrow", pieces: [Piece(bucket: .inbox, status: .done, scheduledIn: 1)], isStalled: true),
        StalledCase(label: "an action scheduled yesterday", pieces: [Piece(bucket: .action, scheduledIn: -1)], isStalled: false),
        StalledCase(label: "a hidden open action", pieces: [Piece(bucket: .action, hiddenFor: 3)], isStalled: false),
        StalledCase(
            label: "an open sub-item under a done action", pieces: [Piece(bucket: .action, status: .done), Piece(bucket: .action, isSubItem: true)],
            isStalled: true),
        StalledCase(
            label: "a done sub-item under a done action",
            pieces: [Piece(bucket: .action, status: .done), Piece(bucket: .action, status: .done, isSubItem: true)], isStalled: true),
        StalledCase(label: "a someday project with no items", status: .someday, pieces: [], isStalled: false),
        StalledCase(label: "a done project with no items", status: .done, pieces: [], isStalled: false),
        StalledCase(label: "a project in the trash with no items", status: .trash, pieces: [], isStalled: false),
        StalledCase(label: "a dropped project with only someday items", status: .dropped, pieces: [Piece(bucket: .someday)], isStalled: false),
    ])
    func stalledFollowsTheRule(_ example: StalledCase) {
        let project = project(example.label, example.status)
        var last: Item?
        for piece in example.pieces {
            let item = Item(title: "Piece", bucket: piece.bucket)
            item.status = piece.status
            item.scheduledDate = piece.scheduledIn.map { Self.today.adding(days: $0).storedDate }
            item.hideUntil = piece.hiddenFor.map { Self.today.adding(days: $0).storedDate }
            context.insert(item)
            item.parent = piece.isSubItem ? last : project
            last = item
        }
        #expect(project.isStalled(today: Self.today) == example.isStalled)
    }

    @Test(arguments: [(-1, false), (0, false), (1, true), (30, true)])
    func hiddenUntilItsDay(daysAhead: Int, isHidden: Bool) {
        let item = Item(title: "Renew passport", bucket: .action)
        item.hideUntil = Self.today.adding(days: daysAhead).storedDate
        context.insert(item)
        #expect(item.isHidden(today: Self.today) == isHidden)
        #expect(item.isInActions(today: Self.today) == !isHidden)
    }

    @Test func showingHiddenListsHiddenItemsAndProjects() {
        let project = project("Garden")
        project.hideUntil = Self.today.adding(days: 2).storedDate
        let inProject = Item(title: "Buy seeds", bucket: .action)
        let waiting = Item(title: "Quote", bucket: .waiting)
        waiting.hideUntil = Self.today.adding(days: 5).storedDate
        context.insert(inProject)
        context.insert(waiting)
        inProject.parent = project
        #expect(!inProject.isInActions(today: Self.today) && !waiting.isListed(today: Self.today, doneSince: nil))
        #expect(inProject.isInActions(today: Self.today, showsHidden: true))
        #expect(waiting.isListed(today: Self.today, doneSince: nil, showsHidden: true))
    }

    @Test func aHiddenItemComesBackAtTheStartOfItsDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let item = Item(title: "Renew passport", bucket: .action)
        item.hideUntil = LocalDate(2026, 10, 22).storedDate
        context.insert(item)
        let boundary = DayBoundary()
        let before = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 3, minute: 59))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 4))!
        #expect(item.isHidden(today: boundary.day(at: before, in: calendar)))
        #expect(!item.isHidden(today: boundary.day(at: after, in: calendar)))
    }

    @Test func aHiddenProjectHidesItsItems() {
        let project = project("Garden")
        project.hideUntil = Self.today.adding(days: 2).storedDate
        let item = Item(title: "Buy seeds", bucket: .action)
        context.insert(item)
        item.parent = project
        #expect(project.isHidden(today: Self.today))
        #expect(item.isHidden(today: Self.today))
        #expect(!item.isInActions(today: Self.today))
        #expect(!item.isHidden(today: Self.today.adding(days: 2)))
    }

    @Test func aHiddenItemHidesItsSubItems() {
        let parent = Item(title: "Paint the shed", bucket: .action)
        parent.hideUntil = Self.today.adding(days: 1).storedDate
        let child = Item(title: "Buy brushes", bucket: .action)
        context.insert(parent)
        context.insert(child)
        child.parent = parent
        #expect(child.isHidden(today: Self.today))
        child.hideUntil = Self.today.adding(days: 5).storedDate
        parent.hideUntil = nil
        #expect(child.isHidden(today: Self.today), "a subtask has its own Hide Until")
    }

    @Test(arguments: [(-60.0, false), (0, true), (60, true)])
    func aDoneItemStaysUntilTheNextDay(secondsAfterTheDayStarted: Double, isShown: Bool) {
        let dayStart = Date(timeIntervalSince1970: 2_000_000)
        let item = Item(title: "Call the bank", bucket: .action)
        context.insert(item)
        item.markDone(at: dayStart.addingTimeInterval(secondsAfterTheDayStarted))
        #expect(item.isInActions(today: Self.today, doneSince: dayStart) == isShown)
        #expect(!item.isInActions(today: Self.today), "open only")
    }

    @Test func aDroppedItemIsntShown() {
        let item = Item(title: "Call the bank", bucket: .action)
        item.status = .dropped
        item.completedAt = .now
        context.insert(item)
        #expect(!item.isInActions(today: Self.today, doneSince: .distantPast))
    }

    @Test(arguments: [(-1, true), (0, true), (1, false)])
    func aScheduledActionIsInActionsFromItsDay(daysAhead: Int, isInActions: Bool) {
        let item = Item(title: "Call the bank", bucket: .action)
        item.scheduledDate = Self.today.adding(days: daysAhead).storedDate
        context.insert(item)
        #expect(item.isInActions(today: Self.today) == isInActions)
    }

    @Test(arguments: [
        (Bucket.action, ItemKind.action, ItemStatus.open, true),
        (.action, .note, .open, false),
        (.action, .action, .done, false),
        (.action, .action, .dropped, false),
        (.inbox, .action, .open, false),
        (.waiting, .action, .open, false),
        (.someday, .action, .open, false),
    ])
    func onlyOpenActionsAreInActions(bucket: Bucket, kind: ItemKind, status: ItemStatus, isInActions: Bool) {
        let item = Item(title: "Call the bank", bucket: bucket)
        item.kind = kind
        item.status = status
        context.insert(item)
        #expect(item.isInActions(today: Self.today) == isInActions)
    }

    @Test(arguments: ProjectState.allCases)
    func onlyActiveProjectsActionsAreInActions(state: ProjectState) {
        let project = project("Garden", state)
        let item = Item(title: "Buy seeds", bucket: .action)
        context.insert(item)
        item.parent = project
        #expect(item.isInActions(today: Self.today) == (state == .active))
        #expect(!project.isInActions(today: Self.today), "a task with a next step under it isn't in Actions itself")
    }

    @Test(arguments: [(ProjectState.active, true), (.someday, false), (.done, false), (.dropped, false), (.trash, false)])
    func aProjectThatsGoneTakesItsItemsOutOfLists(state: ProjectState, isListed: Bool) {
        let project = project("Kitchen", state)
        let item = Item(title: "Quote from the plumber", bucket: .waiting)
        context.insert(item)
        item.parent = project
        #expect(item.isListed(today: Self.today, doneSince: nil) == isListed)
    }

    @Test func subtasksAreListedByThemselvesAndOnlyTheLastAreActions() {
        let project = project("Kitchen")
        let action = Item(title: "Measure the walls", bucket: .action)
        let step = Item(title: "Find the tape measure", bucket: .action)
        context.insert(action)
        context.insert(step)
        action.parent = project
        step.parent = action
        #expect(action.project === project && step.project === action && project.project == nil)
        #expect(action.depth == 1 && step.depth == 2 && project.isProject && action.isProject && !step.isProject)
        #expect([project, action, step].allSatisfy { $0.isListed(today: Self.today, doneSince: nil) })
        #expect(!project.isInActions(today: Self.today) && !action.isInActions(today: Self.today) && step.isInActions(today: Self.today))
    }

    func sequentialProject() -> (Item, [Item]) {
        let project = project("Taxes")
        project.isSequential = true
        let items = ["Gather receipts", "Fill in the form", "Send it"].enumerated().map { index, title in
            let item = Item(title: title, bucket: .action)
            item.sortOrder = Double(index)
            context.insert(item)
            item.parent = project
            return item
        }
        return (project, items)
    }

    @Test func aSequentialProjectShowsOnlyItsFirstOpenAction() {
        let (_, items) = sequentialProject()
        #expect(items.map { $0.isInActions(today: Self.today) } == [true, false, false])
        items[0].status = .done
        #expect(items.map { $0.isInActions(today: Self.today) } == [false, true, false])
    }

    @Test func aSequentialProjectFollowsItsOrderNotWhenItemsWereMade() {
        let (_, items) = sequentialProject()
        items[2].sortOrder = -1
        #expect(items.map { $0.isInActions(today: Self.today) } == [false, false, true])
    }

    @Test func aSequentialTasksFirstBranchIsInActionsAllTheWayDown() {
        let (project, items) = sequentialProject()
        let child = Item(title: "Bank statements", bucket: .action)
        context.insert(child)
        child.parent = items[0]
        let later = Item(title: "Copy the form", bucket: .action)
        context.insert(later)
        later.parent = items[1]
        #expect(child.isInActions(today: Self.today) && !items[0].isInActions(today: Self.today) && !later.isInActions(today: Self.today))
        #expect(project.openSubtasks.map(\.title) == ["Gather receipts", "Fill in the form", "Send it"])
    }

    @Test func aSequentialProjectsNextActionShowsOnceTheFirstIsDone() {
        let (_, items) = sequentialProject()
        let dayStart = Date.now.addingTimeInterval(-60)
        items[0].markDone()
        #expect(items.map { $0.isInActions(today: Self.today, doneSince: dayStart) } == [true, true, false])
    }

    @Test func aParallelProjectShowsEveryOpenAction() {
        let (project, items) = sequentialProject()
        project.isSequential = false
        #expect(items.allSatisfy { $0.isInActions(today: Self.today) })
    }
}
