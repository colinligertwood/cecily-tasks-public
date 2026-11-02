import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// Filing an item puts it in exactly one bucket, not the Inbox, and can be undone.
@MainActor
struct ClarifyTests {
    static let today = LocalDate(2026, 10, 20)
    let container: ModelContainer
    let context: ModelContext
    let calls: Context
    let kitchen: Item

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        try TasksSchema.seed(context)
        calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
        kitchen = context.insertProject("Kitchen refit")
        try context.save()
    }

    func inboxItem(_ title: String = "Insurance") throws -> Item {
        let item = Item(title: title)
        context.insert(item)
        try context.save()
        return item
    }

    @discardableResult
    func finish(_ item: Item, _ outcome: ClarifyOutcome) throws -> Clarifier.Undo {
        let undo = Clarifier.file(item, outcome, today: Self.today)
        try context.save()
        #expect(item.bucket != .inbox, "an item leaves the Inbox")
        return undo
    }

    func outcome(_ destination: ClarifyOutcome.Destination, title: String? = nil, _ fill: (inout ClarifyOutcome) -> Void = { _ in }) -> ClarifyOutcome
    {
        var outcome = ClarifyOutcome(destination)
        outcome.title = title
        fill(&outcome)
        return outcome
    }

    // MARK: Not actionable

    @Test(arguments: [(ClarifyOutcome.Destination.trash, Bucket.trash), (.someday, .someday), (.reference, .reference)])
    func notActionable(destination: ClarifyOutcome.Destination, bucket: Bucket) throws {
        let item = try inboxItem()
        try finish(item, ClarifyOutcome(destination))
        #expect(item.bucket == bucket && item.status == .open)
        #expect((item.trashedAt != nil) == (bucket == .trash))
    }

    // MARK: One step

    @Test func doneNowIsDone() throws {
        let item = try inboxItem("Insurance")
        try finish(item, outcome(.doneNow, title: "Email Sam for the policy number") { $0.secondsTaken = 95 })
        #expect(item.title == "Email Sam for the policy number")
        #expect(item.bucket == .action && item.status == .done && item.completedAt != nil)
    }

    @Test func someoneElseMakesItWaiting() throws {
        let item = try inboxItem()
        try finish(item, outcome(.waiting(person: "Sam", followUp: LocalDate(2026, 10, 27)), title: "Get the quote from Sam"))
        #expect(item.bucket == .waiting && item.waitingOn == "Sam")
        #expect(item.followUpDate.map(LocalDate.init(day:)) == LocalDate(2026, 10, 27))
    }

    @Test func waitingWithNoOneYetLeavesWhoEmpty() throws {
        let item = try inboxItem()
        try finish(item, ClarifyOutcome(.waiting(person: "", followUp: nil)))
        #expect(item.bucket == .waiting && item.waitingOn == nil)
    }

    @Test func aDayAndTimeMakeItScheduled() throws {
        let item = try inboxItem()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        Clarifier.file(
            item, outcome(.scheduled(date: LocalDate(2026, 11, 3), time: 14 * 60 + 30), title: "Dentist"), today: Self.today, calendar: calendar)
        try context.save()
        #expect(item.bucket == .action && item.scheduledDate.map(LocalDate.init(day:)) == LocalDate(2026, 11, 3))
        let time = try #require(item.scheduledTime)
        #expect(calendar.component(.hour, from: time) == 14 && calendar.component(.minute, from: time) == 30)
    }

    @Test func aDayWithoutATime() throws {
        let item = try inboxItem()
        try finish(item, outcome(.scheduled(date: LocalDate(2026, 11, 1), time: nil), title: "Renew the car tax"))
        #expect(item.scheduledDate != nil && item.scheduledTime == nil)
    }

    @Test func otherwiseItGoesToActionsWithItsContext() throws {
        let item = try inboxItem()
        try finish(
            item,
            outcome(.action, title: "Call the insurer about the renewal") {
                $0.contexts = [calls.id]
                $0.timeEstimate = .fifteenMinutes
                $0.energy = .low
            })
        #expect(item.bucket == .action && item.contexts?.map(\.name) == ["Calls"])
        #expect(item.timeEstimate == .fifteenMinutes && item.energy == .low)
    }

    // MARK: Projects

    @Test(arguments: [
        ClarifyOutcome.Destination.doneNow, .waiting(person: "Alex", followUp: nil), .scheduled(date: LocalDate(2026, 10, 24), time: nil), .action,
    ])
    func aNewProjectWithThisAsItsFirstAction(destination: ClarifyOutcome.Destination) throws {
        let item = try inboxItem("Bathroom")
        try finish(
            item,
            outcome(destination, title: "Measure the bathroom") {
                $0.project = .new(title: "New bathroom fitted", moreActions: ["Choose tiles", " ", "Book plumber"])
            })
        let project = try #require(item.project)
        #expect(project.title == "New bathroom fitted" && project.isActive)
        #expect(Set(project.children?.map(\.title) ?? []) == ["Measure the bathroom", "Choose tiles", "Book plumber"])
        #expect(project.children?.allSatisfy { $0.bucket != .inbox } == true)
    }

    @Test func anExistingProject() throws {
        let item = try inboxItem()
        try finish(item, outcome(.action, title: "Order the worktop") { $0.project = .existing(kitchen.id) })
        #expect(item.project?.title == "Kitchen refit" && item.bucket == .action)
    }

    // MARK: Details

    @Test func theOptionalFieldsAreFilledIn() throws {
        let area = Area(name: "Home")
        context.insert(area)
        let item = try inboxItem()
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=1")))
        try finish(
            item,
            outcome(.action, title: "Pay the council tax") {
                $0.dueDate = LocalDate(2026, 11, 1)
                $0.hideUntil = LocalDate(2026, 10, 28)
                $0.timeEstimate = .fiveMinutes
                $0.energy = .medium
                $0.repeatRule = rule
                $0.area = area.id
            })
        #expect(item.dueDate.map(LocalDate.init(day:)) == LocalDate(2026, 11, 1))
        #expect(item.hideUntil.map(LocalDate.init(day:)) == LocalDate(2026, 10, 28))
        #expect(item.timeEstimate == .fiveMinutes && item.energy == .medium && item.area?.name == "Home")
        #expect(item.repeatRule?.rule == rule)
    }

    // MARK: Undo

    @Test func undoPutsTheItemBackInTheInbox() throws {
        let item = try inboxItem("Insurance")
        item.contexts = [calls]
        try context.save()
        let undo = try finish(
            item,
            outcome(.waiting(person: "Sam", followUp: LocalDate(2026, 10, 27)), title: "Call the insurer") {
                $0.project = .existing(kitchen.id)
                $0.dueDate = LocalDate(2026, 11, 1)
            })
        #expect(Clarifier.undo(undo, in: context))
        try context.save()
        #expect(item.bucket == .inbox && item.title == "Insurance" && item.waitingOn == nil && item.followUpDate == nil)
        #expect(item.dueDate == nil && item.project == nil && item.contexts?.map(\.name) == ["Calls"])
    }

    @Test func undoDeletesWhatTheDecisionMade() throws {
        let item = try inboxItem("Bathroom")
        let undo = try finish(
            item,
            outcome(.action, title: "Measure") {
                $0.project = .new(title: "New bathroom", moreActions: ["Choose tiles"])
                $0.repeatRule = RepeatRule(.afterCompletion(value: 1, unit: .week))
            })
        #expect(Set(try context.fetch(FetchDescriptor<Item>()).map(\.title)) == ["Kitchen refit", "New bathroom", "Measure", "Choose tiles"])
        #expect(item.project?.title == "New bathroom" && item.project?.isProject == true)
        Clarifier.undo(undo, in: context)
        try context.save()
        let items = try context.fetch(FetchDescriptor<Item>())
        #expect(Set(items.map(\.title)) == ["Kitchen refit", "Bathroom"])
        #expect(try context.fetchCount(FetchDescriptor<Repetition>()) == 0 && item.repeatRule == nil)
    }

    @Test func undoRestoresARepeatThatWasChanged() throws {
        let item = try inboxItem()
        let repetition = Repetition()
        repetition.rule = RepeatRule(.afterCompletion(value: 2, unit: .day))
        context.insert(repetition)
        item.repeatRule = repetition
        try context.save()
        var outcome = ClarifyOutcome(.action)
        outcome.repeatRule = RepeatRule(.afterCompletion(value: 1, unit: .month))
        let undo = Clarifier.file(item, outcome, today: Self.today)
        #expect(item.repeatRule?.rule == RepeatRule(.afterCompletion(value: 1, unit: .month)))
        Clarifier.undo(undo, in: context)
        #expect(item.repeatRule?.rule == RepeatRule(.afterCompletion(value: 2, unit: .day)))
    }

    @Test func undoneDecisionsCanBeRedone() throws {
        let item = try inboxItem("Insurance")
        let undo = Clarifier.file(item, ClarifyOutcome(.someday), today: Self.today)
        try context.save()
        #expect(undo.current(in: context) != nil)
        let redo = try #require(undo.current(in: context))
        Clarifier.undo(undo, in: context)
        #expect(item.bucket == .inbox)
        Clarifier.undo(redo, in: context)
        #expect(item.bucket == .someday)
    }

    @Test func aDecisionThatMadeRecordsCantBeRedone() throws {
        let item = try inboxItem("Bathroom")
        var outcome = ClarifyOutcome(.action)
        outcome.project = .new(title: "New bathroom", moreActions: [])
        let undo = Clarifier.file(item, outcome, today: Self.today)
        #expect(undo.current(in: context) == nil)
    }

    @Test func undoingAnItemDeletedMeanwhileDoesNothing() throws {
        let item = try inboxItem()
        let undo = Clarifier.file(item, ClarifyOutcome(.someday), today: Self.today)
        context.delete(item)
        try context.save()
        #expect(!Clarifier.undo(undo, in: context))
    }
}
