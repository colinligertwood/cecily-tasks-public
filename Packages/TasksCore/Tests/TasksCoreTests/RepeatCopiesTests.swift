import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// Marking a repeating item done makes its next copy. Each case's dates are worked out by hand.
@MainActor
struct RepeatCopiesTests {
    static let today = LocalDate(2026, 10, 21)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        try TasksSchema.seed(context)
    }

    func repeating(_ title: String, _ rule: RepeatRule, scheduled: LocalDate? = nil, due: LocalDate? = nil) throws -> Item {
        let item = Item(title: title, bucket: .action)
        item.scheduledDate = scheduled?.storedDate
        item.dueDate = due?.storedDate
        context.insert(item)
        let repetition = Repetition()
        repetition.rule = rule
        repetition.naturalText = "every week"
        context.insert(repetition)
        item.repeatRule = repetition
        try context.save()
        return item
    }

    func weekly(on day: String) throws -> RepeatRule {
        RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=\(day)")))
    }

    func done(_ items: [Item], on day: LocalDate = Self.today) -> Clarifier.Undo? {
        Clarifier.toggleDone(items, today: day, in: context).undo
    }

    func copy(of item: Item) throws -> Item? {
        let id = item.nextCopyID
        return try context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
    }

    @Test func aWeeklyItemsCopyMovesItsDatesOnAWeekAndTakesTheRepeat() throws {
        // Tuesday 20 October, due Friday 23 October; done Wednesday 21: the next Tuesday is 27 October.
        let item = try repeating("Bins out", try weekly(on: "TU"), scheduled: LocalDate(2026, 10, 20), due: LocalDate(2026, 10, 23))
        let repetition = try #require(item.repeatRule)
        _ = done([item])
        let copy = try #require(try copy(of: item))
        #expect(item.status == .done && copy.status == .open && copy.title == "Bins out")
        #expect(copy.day(.scheduled) == LocalDate(2026, 10, 27) && copy.day(.due) == LocalDate(2026, 10, 30))
        #expect(copy.hideUntil == nil && copy.repeatRule === repetition && item.repeatRule == nil)
    }

    @Test func showingEarlyHidesTheCopyUntilThatManyDaysBefore() throws {
        // Due on the 1st of each month, shown 3 days before: done 21 October, next 1 November, shown from 29 October.
        var rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=MONTHLY;BYMONTHDAY=1")))
        rule.showDaysBefore = 3
        let item = try repeating("Pay rent", rule, due: LocalDate(2026, 10, 1))
        _ = done([item])
        let copy = try #require(try copy(of: item))
        #expect(copy.day(.due) == LocalDate(2026, 11, 1) && copy.day(.hideUntil) == LocalDate(2026, 10, 29) && copy.scheduledDate == nil)
    }

    @Test func anUndatedItemAfterCompletionStartsThatLongAfterItsDone() throws {
        // 3 days after done, done 21 October: starts 24 October.
        let item = try repeating("Water the plants", RepeatRule(.afterCompletion(value: 3, unit: .day)))
        _ = done([item])
        #expect(try copy(of: item)?.day(.scheduled) == LocalDate(2026, 10, 24))
    }

    @Test func datesThatPassedWhileItWasOpenAreSkipped() throws {
        // Every Monday from 5 October, done 21 October: 12 and 19 October have passed, so 26 October.
        let item = try repeating("Weekly report", try weekly(on: "MO"), scheduled: LocalDate(2026, 10, 5))
        _ = done([item])
        #expect(try copy(of: item)?.day(.scheduled) == LocalDate(2026, 10, 26))
    }

    @Test func aCountedRepeatEndsAfterItsLastCopy() throws {
        var rule = try weekly(on: "TU")
        rule.remainingCount = 1
        let item = try repeating("Physio exercises", rule, scheduled: LocalDate(2026, 10, 20))
        _ = done([item])
        let copy = try #require(try copy(of: item))
        #expect(copy.repeatRule?.remainingCount == 0)
        _ = done([copy], on: LocalDate(2026, 10, 27))
        #expect(try self.copy(of: copy) == nil)
    }

    @Test func aRepeatPastItsEndMakesNoCopy() throws {
        var rule = try weekly(on: "TU")
        rule.endDate = LocalDate(2026, 10, 25)
        let item = try repeating("Bins out", rule, scheduled: LocalDate(2026, 10, 20))
        _ = done([item])
        #expect(try copy(of: item) == nil && item.repeatRule != nil)
    }

    @Test func theCopyKeepsItsPlaceAndDetailsAndItsSubtasksStartAgain() throws {
        let project = context.insertProject("Garden")
        let calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
        let item = try repeating("Check the mower", try weekly(on: "TU"), scheduled: LocalDate(2026, 10, 20))
        item.parent = project
        item.contexts = [calls]
        item.energy = .low
        let step = Item(title: "Oil", bucket: .action)
        context.insert(step)
        step.parent = item
        _ = done([item])
        let copy = try #require(try copy(of: item))
        #expect(copy.project === project && copy.contexts?.map(\.name) == ["Calls"] && copy.energy == .low)
        #expect(copy.children?.map(\.title) == ["Oil"] && copy.children?.allSatisfy { $0.status == .open } == true)
        let oil = try #require(copy.children?.first)
        #expect(step.status == .done && !copy.isInActions(today: LocalDate(2026, 10, 27)) && oil.isInActions(today: LocalDate(2026, 10, 27)))
    }

    @Test func undoingDoneDeletesTheCopyAndGivesTheRepeatBack() throws {
        let item = try repeating("Bins out", try weekly(on: "TU"), scheduled: LocalDate(2026, 10, 20))
        let repetition = try #require(item.repeatRule)
        let undo = try #require(done([item]))
        try context.save()
        Clarifier.undo(undo, in: context)
        try context.save()
        #expect(item.status == .open)
        #expect(item.repeatRule === repetition)
        #expect(try copy(of: item) == nil)
    }

    @Test func uncheckingTakesBackAnOpenCopyAndItsCountedRepeat() throws {
        var rule = try weekly(on: "TU")
        rule.remainingCount = 3
        let item = try repeating("Bins out", rule, scheduled: LocalDate(2026, 10, 20))
        _ = done([item])
        try context.save()
        let reopened = Clarifier.toggleDone([item], today: Self.today, in: context)
        try context.save()
        #expect(try reopened.reopened && item.status == .open && copy(of: item) == nil)
        #expect(item.repeatRule?.remainingCount == 3)
    }

    @Test func aCopyThatsBeenDoneIsntTakenBack() throws {
        let item = try repeating("Bins out", try weekly(on: "TU"), scheduled: LocalDate(2026, 10, 20))
        _ = done([item])
        let copy = try #require(try copy(of: item))
        _ = done([copy], on: LocalDate(2026, 10, 27))
        _ = Clarifier.toggleDone([item], today: Self.today, in: context)
        #expect(try copy.status == .done && self.copy(of: item) != nil)
    }

    @Test func theCopysIDIsTheSameOnEveryDeviceAndMadeOnce() throws {
        let item = try repeating("Bins out", try weekly(on: "TU"), scheduled: LocalDate(2026, 10, 20))
        #expect(item.nextCopyID == item.nextCopyID && item.nextCopyID != item.id)
        _ = done([item])
        #expect(RepeatCopies.makeNext(after: item, closedOn: Self.today, in: context) == nil)
        #expect(try context.fetch(FetchDescriptor<Item>()).count { $0.title == "Bins out" } == 2)
    }
}
