import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// The structured repeat editor's choices, read from rules and written back, and what the repeat
/// editor shows and does. Dates are worked out by hand from a 2026 calendar: 21 October 2026 is a
/// Wednesday.
@MainActor
struct RepeatChoicesTests {
    nonisolated static let today = LocalDate(2026, 10, 21)

    /// Everyday ways of saying a repeat, each as a rule.
    nonisolated static let examples: [(String, RepeatRule)] = {
        func schedule(_ rrule: String, endDate: LocalDate? = nil, remaining: Int? = nil) -> RepeatRule {
            RepeatRule(.schedule(try! Recurrence(rrule: rrule)), endDate: endDate, remainingCount: remaining)
        }
        return [
            ("every weekday", schedule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")),
            ("every weekday, as daily", schedule("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR")),
            ("every 2 weeks on Mon and Thu", schedule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH")),
            ("last Friday of each month", schedule("FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1")),
            ("last Friday, as an ordinal", schedule("FREQ=MONTHLY;BYDAY=-1FR")),
            ("1st and 15th of each month", schedule("FREQ=MONTHLY;BYMONTHDAY=1,15")),
            ("last weekday of the month", schedule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")),
            ("every 3 months on the 2nd Tuesday", schedule("FREQ=MONTHLY;INTERVAL=3;BYDAY=2TU")),
            ("every year on 15 Mar", schedule("FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15")),
            ("every 6 weeks until 31 Dec", schedule("FREQ=WEEKLY;INTERVAL=6", endDate: LocalDate(2026, 12, 31))),
            ("every day, 10 times", schedule("FREQ=DAILY", remaining: 9)),
        ]
    }()

    @Test(arguments: examples)
    func everyExampleRoundTripsThroughTheEditor(_ name: String, _ rule: RepeatRule) {
        let written = RepeatChoices(rule: rule, anchor: Self.today).rule
        #expect(written.upcoming(after: Self.today, count: 40) == rule.upcoming(after: Self.today, count: 40), "\(name)")
        #expect(RepeatChoices(rule: written, anchor: Self.today) == RepeatChoices(rule: rule, anchor: Self.today), "\(name)")
    }

    @Test func choicesForTheLastFridayOfTheMonth() {
        var choices = RepeatChoices(rule: nil, anchor: Self.today)
        choices.frequency = .monthly
        choices.monthlyBy = .position
        choices.position = -1
        choices.positionDay = .weekday(.friday)
        // The last Fridays after 21 October: 30 October, 27 November, 25 December.
        #expect(choices.rule.upcoming(after: Self.today, count: 3) == [LocalDate(2026, 10, 30), LocalDate(2026, 11, 27), LocalDate(2026, 12, 25)])
        #expect(choices.rule.summary == "Monthly on the last Friday")
    }

    @Test func aNewRepeatStartsWeeklyOnTheAnchorsDay() {
        let choices = RepeatChoices(rule: nil, anchor: Self.today)
        #expect(choices.frequency == .weekly && choices.weekdays == [.wednesday])
        #expect(choices.monthDays == [21] && choices.months == Set(1...12) && choices.position == 3)
    }

    @Test func anEndOnADayIsTheNumberOfTimesUpToIt() throws {
        // Every 6 weeks from Wednesday 21 October until 31 December: 21 October, 2 December, so twice.
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;INTERVAL=6")), endDate: LocalDate(2026, 12, 31))
        let choices = RepeatChoices(rule: rule, anchor: Self.today)
        #expect(choices.times == 2)
        #expect(choices.rule.endDate == nil && choices.rule.remainingCount == 1)
    }

    @Test func theLastTimesDate() {
        // Daily from Wednesday 21 October: once is today, 10 times ends on Friday 30 October.
        var choices = RepeatChoices(rule: nil, anchor: Self.today)
        choices.frequency = .daily
        choices.times = 4
        #expect(choices.lastDate(times: 1, from: Self.today) == Self.today)
        #expect(choices.lastDate(times: 10, from: Self.today) == LocalDate(2026, 10, 30))
    }

    @Test(arguments: [
        // From Wednesday 21 October: every 3 days; every 2 weeks on Wednesday; monthly on the 21st.
        (RepeatRule.Unit.day, 3, [LocalDate(2026, 10, 24), LocalDate(2026, 10, 27)]),
        (.week, 2, [LocalDate(2026, 11, 4), LocalDate(2026, 11, 18)]),
        (.month, 1, [LocalDate(2026, 11, 21), LocalDate(2026, 12, 21)]),
        (.month, 2, [LocalDate(2026, 12, 21), LocalDate(2027, 2, 21)]),
    ])
    func aRepeatAfterDoneReadsAsTheSameSchedule(_ unit: RepeatRule.Unit, _ value: Int, _ dates: [LocalDate]) {
        let rule = RepeatChoices(rule: RepeatRule(.afterCompletion(value: value, unit: unit)), anchor: Self.today).rule
        guard case .schedule = rule.mode else {
            Issue.record("Not on a schedule")
            return
        }
        #expect(rule.upcoming(after: Self.today, count: 2) == dates)
    }

    @Test func aYearlyRepeatIsMonthlyInItsMonth() throws {
        let yearly = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15")))
        let choices = RepeatChoices(rule: yearly, anchor: Self.today)
        #expect(choices.frequency == .monthly && choices.months == [3] && choices.monthDays == [15])
        #expect(choices.rule.mode == .schedule(try Recurrence(rrule: "FREQ=MONTHLY;BYMONTH=3;BYMONTHDAY=15")))
        #expect(choices.rule.summary == "Every year on 15 March")
    }

    @Test func everySoManyMonthsIsTheMonthsItFallsIn() throws {
        // Every 3 months from October: October, January, April and July.
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1")))
        let choices = RepeatChoices(rule: rule, anchor: Self.today)
        #expect(choices.months == [1, 4, 7, 10])
        #expect(choices.rule.mode == .schedule(try Recurrence(rrule: "FREQ=MONTHLY;BYMONTH=1,4,7,10;BYMONTHDAY=1")))
    }

    @Test(arguments: ["FREQ=YEARLY;INTERVAL=2", "FREQ=MONTHLY;INTERVAL=5"])
    func intervalsAMonthsChoiceCantHoldAreOnceAYear(_ rrule: String) throws {
        // From 21 October: every October, on the 21st.
        let choices = RepeatChoices(rule: RepeatRule(.schedule(try Recurrence(rrule: rrule))), anchor: Self.today)
        #expect(choices.months == [10] && choices.interval == 1)
        #expect(choices.rule.upcoming(after: Self.today, count: 2) == [LocalDate(2027, 10, 21), LocalDate(2028, 10, 21)])
    }

    @Test func anEndAfterSoManyTimesCountsThisOne() {
        var choices = RepeatChoices(rule: nil, anchor: Self.today)
        choices.frequency = .daily
        choices.times = 3
        // This one, then 22 and 23 October.
        #expect(choices.rule.remainingCount == 2)
        #expect(choices.rule.upcoming(after: Self.today) == [LocalDate(2026, 10, 22), LocalDate(2026, 10, 23)])
        #expect(choices.rule.summary == "Every day, 3 times")
    }

    @Test(arguments: [
        ("FREQ=MONTHLY;BYMONTHDAY=1,15", "Monthly on the 1st and 15th"),
        ("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", "Monthly on the last weekday"),
        ("FREQ=MONTHLY;BYDAY=SA,SU;BYSETPOS=1", "Monthly on the first weekend day"),
        ("FREQ=MONTHLY;BYMONTH=3,9;BYMONTHDAY=1", "Monthly on the 1st in March and September"),
        ("FREQ=MONTHLY;BYMONTH=1,2,3,4,5,6,7,8,10,11,12;BYMONTHDAY=21", "Monthly on the 21st, except September"),
        ("FREQ=MONTHLY;BYMONTH=12;BYDAY=-1FR", "Every year on the last Friday of December"),
    ])
    func summaries(_ rrule: String, _ expected: String) throws {
        #expect(RepeatRule(.schedule(try Recurrence(rrule: rrule))).summary == expected)
    }

    @Test(arguments: [
        ("FREQ=DAILY", "Daily"),
        ("FREQ=DAILY;INTERVAL=3", "Every 3 days"),
        ("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "Weekdays"),
        ("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", "Weekdays"),
        ("FREQ=WEEKLY;BYDAY=TH,MO", "Mon, Thu"),
        ("FREQ=WEEKLY;BYDAY=MO,TU,WE,FR", "Weekly…"),
        ("FREQ=WEEKLY", "Weekly"),
        ("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", "Every 2 weeks, Mon"),
        ("FREQ=MONTHLY;BYMONTHDAY=21", "Monthly, 21st"),
        ("FREQ=MONTHLY;BYMONTHDAY=1,15", "Monthly, 1st, 15th"),
        ("FREQ=MONTHLY;BYMONTHDAY=1,10,20", "Monthly, 1st, 10th…"),
        ("FREQ=MONTHLY;BYMONTHDAY=-1", "Monthly, last day"),
        ("FREQ=MONTHLY;BYMONTH=1,2,3,4,5,6,7,8,10,11,12;BYMONTHDAY=21", "Monthly, 21st…"),
        ("FREQ=MONTHLY;BYDAY=-1FR", "Monthly, last Fri"),
        ("FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1", "Monthly, last Fri"),
        ("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1", "Monthly, 1st weekday"),
        ("FREQ=MONTHLY", "Monthly"),
        ("FREQ=MONTHLY;BYMONTH=3;BYMONTHDAY=15", "Yearly, 15 Mar"),
        ("FREQ=MONTHLY;BYMONTH=12;BYDAY=-1FR", "Yearly, last Fri in Dec"),
        ("FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15", "Yearly, 15 Mar"),
        ("FREQ=DAILY;COUNT=10", "Daily…"),
    ])
    func labels(_ rrule: String, _ expected: String) throws {
        #expect(RepeatRule(.schedule(try Recurrence(rrule: rrule))).label == expected)
    }

    @Test func anEndIsLeftOutOfTheLabel() throws {
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")), remainingCount: 9)
        #expect(rule.label == "Weekdays…")
    }

    @Test func summariesSayWhenItEnds() {
        #expect(
            RepeatRule(.afterCompletion(value: 2, unit: .week), endDate: LocalDate(2026, 12, 31)).summary == "2 weeks after done, until 31 Dec 2026")
        #expect(RepeatRule(.afterCompletion(value: 1, unit: .day)).summary == "1 day after done")
    }

    @Test func theNextFiveDates() throws {
        // Every 2 weeks on Monday, from Monday 26 October.
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO")))
        #expect(
            rule.upcoming(after: LocalDate(2026, 10, 26)) == [
                LocalDate(2026, 11, 9), LocalDate(2026, 11, 23), LocalDate(2026, 12, 7), LocalDate(2026, 12, 21), LocalDate(2027, 1, 4),
            ])
        // 1 month after done, each taken as done on its day.
        #expect(
            RepeatRule(.afterCompletion(value: 1, unit: .month)).upcoming(after: LocalDate(2026, 10, 31), count: 3) == [
                LocalDate(2026, 11, 30), LocalDate(2026, 12, 30), LocalDate(2027, 1, 30),
            ])
    }

    @Test(arguments: [
        // Weekly with no weekday, on Monday 26 October: it stays on Mondays.
        ("FREQ=WEEKLY", LocalDate(2026, 10, 26), "FREQ=WEEKLY;BYDAY=MO"),
        // Monthly on the 26th.
        ("FREQ=MONTHLY", LocalDate(2026, 10, 26), "FREQ=MONTHLY;BYMONTHDAY=26"),
        ("FREQ=YEARLY", LocalDate(2026, 10, 26), "FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=26"),
        ("FREQ=WEEKLY;BYDAY=TU", LocalDate(2026, 10, 27), "FREQ=WEEKLY;BYDAY=TU"),
        ("FREQ=DAILY;INTERVAL=2", LocalDate(2026, 10, 27), "FREQ=DAILY;INTERVAL=2"),
    ])
    func pinning(_ rrule: String, _ day: LocalDate, _ expected: String) throws {
        let pinned = RepeatRule(.schedule(try Recurrence(rrule: rrule))).pinned(to: day)
        #expect(pinned.mode == .schedule(try Recurrence(rrule: expected)))
    }
}

/// Moving, skipping and changing the repeat of a repeating copy.
@MainActor
struct RepeatChangesTests {
    let context: ModelContext

    init() throws {
        context = ModelContext(try TasksSchema.container(at: nil))
        try TasksSchema.seed(context)
    }

    func repeating(_ rrule: String, scheduled: LocalDate?, due: LocalDate? = nil) throws -> Item {
        let item = Item(title: "Bins out", bucket: .action)
        item.scheduledDate = scheduled?.storedDate
        item.dueDate = due?.storedDate
        context.insert(item)
        item.setRepeat(RepeatRule(.schedule(try Recurrence(rrule: rrule))), text: "every week", in: context)
        try context.save()
        return item
    }

    func copy(of item: Item) throws -> Item? {
        let id = item.nextCopyID
        return try context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
    }

    @Test func movingThisOneKeepsTheCopiesAfterItOnTheirDay() throws {
        // Weekly from Monday 26 October, moved to Wednesday 28 and done that day: the next is still
        // Monday 2 November.
        let item = try repeating("FREQ=WEEKLY", scheduled: LocalDate(2026, 10, 26))
        item.setDay(LocalDate(2026, 10, 28), for: .scheduled)
        _ = Clarifier.toggleDone([item], today: LocalDate(2026, 10, 28), in: context)
        #expect(try copy(of: item)?.day(.scheduled) == LocalDate(2026, 11, 2))
    }

    @Test func startingOnAnotherDayMovesThisOneOnly() throws {
        // Monthly from Monday 26 October, started on Wednesday 28 and done then: November's is
        // still the 26th.
        let item = try repeating("FREQ=MONTHLY", scheduled: LocalDate(2026, 10, 26))
        item.start(on: LocalDate(2026, 10, 28), in: .current)
        _ = Clarifier.toggleDone([item], today: LocalDate(2026, 10, 28), in: context)
        #expect(try copy(of: item)?.day(.scheduled) == LocalDate(2026, 11, 26))
    }

    @Test func skippingDropsThisOneAndMakesTheNext() throws {
        // Every Tuesday from 20 October, skipped on Wednesday 21: the next is 27 October.
        let item = try repeating("FREQ=WEEKLY;BYDAY=TU", scheduled: LocalDate(2026, 10, 20))
        let undo = try #require(RepeatCopies.skip([item], today: LocalDate(2026, 10, 21), in: context))
        let next = try #require(try copy(of: item))
        #expect(item.status == .dropped && item.completedAt == nil)
        #expect(next.status == .open && next.day(.scheduled) == LocalDate(2026, 10, 27) && next.repeatRule != nil)

        Clarifier.undo(undo, in: context)
        #expect(item.status == .open && item.repeatRule != nil)
        #expect(try copy(of: item) == nil)
    }

    @Test func skippingSomethingThatDoesntRepeatDoesNothing() {
        let item = Item(title: "Once", bucket: .action)
        context.insert(item)
        #expect(RepeatCopies.skip([item], today: LocalDate(2026, 10, 21), in: context) == nil)
        #expect(item.status == .open)
    }

    @Test func changingAllUpcomingMovesThisOneAndChangesTheRule() throws {
        // Every Tuesday from 20 October, due 23 October; changed on Wednesday 21 to every Friday:
        // this one moves to Friday 23, its due date with it, and the next is 30 October.
        let item = try repeating("FREQ=WEEKLY;BYDAY=TU", scheduled: LocalDate(2026, 10, 20), due: LocalDate(2026, 10, 23))
        let friday = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=FR")))
        RepeatCopies.change(item, to: friday, text: "every friday", thisOneOnly: false, today: LocalDate(2026, 10, 21), in: context)
        #expect(item.day(.scheduled) == LocalDate(2026, 10, 23) && item.day(.due) == LocalDate(2026, 10, 26))
        #expect(item.repeatRule?.rule == friday && item.repeatRule?.naturalText == "every friday")
        _ = Clarifier.toggleDone([item], today: LocalDate(2026, 10, 23), in: context)
        #expect(try copy(of: item)?.day(.scheduled) == LocalDate(2026, 10, 30))
    }

    @Test func changingThisOneKeepsTheRule() throws {
        // Weekly from Tuesday 20 October; this one changed on Wednesday 21 to every Friday: it moves
        // to Friday 23, and the next is still a Tuesday, 27 October.
        let item = try repeating("FREQ=WEEKLY", scheduled: LocalDate(2026, 10, 20))
        let friday = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=FR")))
        RepeatCopies.change(item, to: friday, text: "every friday", thisOneOnly: true, today: LocalDate(2026, 10, 21), in: context)
        #expect(item.day(.scheduled) == LocalDate(2026, 10, 23))
        #expect(item.repeatRule?.naturalText == "every week")
        _ = Clarifier.toggleDone([item], today: LocalDate(2026, 10, 23), in: context)
        #expect(try copy(of: item)?.day(.scheduled) == LocalDate(2026, 10, 27))
    }

    @Test func changingAnUndatedItemSchedulesIt() throws {
        let item = try repeating("FREQ=WEEKLY;BYDAY=TU", scheduled: nil)
        let friday = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=FR")))
        RepeatCopies.change(item, to: friday, text: "every friday", thisOneOnly: false, today: LocalDate(2026, 10, 21), in: context)
        #expect(item.day(.scheduled) == LocalDate(2026, 10, 23))
    }
}
