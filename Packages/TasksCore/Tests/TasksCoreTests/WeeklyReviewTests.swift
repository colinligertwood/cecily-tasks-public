import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct WeeklyReviewTests {
    static let calendar = DaylightSavingTests.calendar("Europe/London")
    /// A Tuesday.
    static let today = LocalDate(2026, 10, 20)
    static let boundary = DayBoundary()
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
    }

    func moment(_ days: Int, _ hour: Int, _ minute: Int = 0, from day: LocalDate = Self.today) -> Date {
        day.adding(days: days).date(in: Self.calendar, hour: hour, minute: minute)
    }

    func records() throws -> [ReviewRecord] {
        try context.fetch(FetchDescriptor<ReviewRecord>())
    }

    @discardableResult
    func finished(at date: Date, started: Date? = nil) -> ReviewRecord {
        let record = ReviewRecord()
        record.startedAt = started ?? date
        record.completedAt = date
        record.stepsDone = ReviewList.allCases.map(\.rawValue)
        context.insert(record)
        return record
    }

    // MARK: Starting, ticking and finishing

    @Test func startingOpensOneReviewAndStartingAgainKeepsIt() throws {
        let first = WeeklyReview.start(in: context, at: moment(0, 10))
        let again = WeeklyReview.start(in: context, at: moment(0, 11))
        #expect(first.id == again.id)
        #expect(try records().count == 1)
        #expect(WeeklyReview.current(try records())?.startedAt == moment(0, 10))
        #expect(WeeklyReview.next(try records()) == .agenda)
    }

    @Test func tickingGoesThroughTheListsInTheSidebarsOrder() throws {
        WeeklyReview.start(in: context, at: moment(0, 10))
        WeeklyReview.tick(.agenda, in: context, at: moment(0, 10, 5))
        WeeklyReview.tick(.actions, in: context, at: moment(0, 10, 9))
        WeeklyReview.tick(.actions, in: context, at: moment(0, 10, 10))
        let records = try records()
        #expect(WeeklyReview.ticked(records) == [.agenda, .actions])
        #expect(WeeklyReview.next(records) == .inbox)
        #expect(records.first?.stepsDone == ["agenda", "actions"])
        #expect(records.first?.modifiedAt == moment(0, 10, 9))
    }

    @Test func tickingTheLastListFinishesTheReview() throws {
        for (minute, list) in ReviewList.allCases.enumerated() {
            #expect(WeeklyReview.current(try records())?.completedAt == nil)
            WeeklyReview.tick(list, in: context, at: moment(0, 10, minute))
        }
        let records = try records()
        #expect(records.count == 1)
        #expect(records.first?.completedAt == moment(0, 10, 4))
        #expect(WeeklyReview.current(records) == nil)
        #expect(WeeklyReview.ticked(records).isEmpty)
    }

    @Test func finishingWithListsUntickedCountsAsFinished() throws {
        WeeklyReview.tick(.inbox, in: context, at: moment(0, 10))
        WeeklyReview.finish(in: context, at: moment(0, 11))
        let records = try records()
        #expect(records.first?.completedAt == moment(0, 11))
        #expect(records.first?.stepsDone == ["inbox"])
        #expect(WeeklyReview.lastFinished(records) == moment(0, 11))
    }

    @Test func reviewsStartedOnTwoDevicesAreOneAndFinishingJoinsThem() throws {
        let later = ReviewRecord()
        later.startedAt = moment(0, 10, 30)
        later.stepsDone = ["waiting", "inbox"]
        let earlier = ReviewRecord()
        earlier.startedAt = moment(0, 10)
        earlier.stepsDone = ["agenda", "inbox"]
        context.insert(later)
        context.insert(earlier)

        #expect(WeeklyReview.current(try records())?.id == earlier.id)
        #expect(WeeklyReview.ticked(try records()) == [.agenda, .inbox, .waiting])
        #expect(WeeklyReview.next(try records()) == .actions)
        WeeklyReview.tick(.actions, in: context, at: moment(0, 11))
        #expect(earlier.stepsDone == ["agenda", "inbox", "actions"])

        WeeklyReview.finish(in: context, at: moment(0, 12))
        let records = try records()
        #expect(records.map(\.id) == [earlier.id])
        #expect(records.first?.stepsDone == ["agenda", "inbox", "actions", "waiting"])
        #expect(records.first?.completedAt == moment(0, 12))
    }

    // MARK: Missed

    struct MissedCase: CustomTestStringConvertible, Sendable {
        let note: String
        /// When the last review was finished, in days and hours from today; nil for none.
        let finished: (days: Int, hour: Int)?
        let isOpen: Bool
        let now: (days: Int, hour: Int)
        let missed: Bool
        var testDescription: String { note }
    }

    @Test(arguments: [
        MissedCase(note: "13 days after a review", finished: (-13, 15), isOpen: false, now: (0, 12), missed: false),
        MissedCase(note: "14 days after a review", finished: (-14, 15), isOpen: false, now: (0, 12), missed: true),
        MissedCase(note: "the 14th day starts at 04:00", finished: (-14, 15), isOpen: false, now: (0, 3), missed: false),
        MissedCase(note: "a review finished at 2 a.m. was the day before", finished: (-13, 2), isOpen: false, now: (0, 12), missed: true),
        MissedCase(note: "never reviewed, 14 days after first launch", finished: nil, isOpen: false, now: (0, 12), missed: true),
        MissedCase(note: "never reviewed, 10 days after first launch", finished: nil, isOpen: false, now: (-4, 12), missed: false),
        MissedCase(note: "a review is open", finished: (-30, 15), isOpen: true, now: (0, 12), missed: false),
    ])
    func missed(_ example: MissedCase) throws {
        if let finished = example.finished { self.finished(at: moment(finished.days, finished.hour)) }
        if example.isOpen { WeeklyReview.start(in: context, at: moment(-1, 9)) }
        let firstLaunch = moment(-14, 9)
        let now = moment(example.now.days, example.now.hour)
        #expect(
            WeeklyReview.isMissed(try records(), firstLaunch: firstLaunch, now: now, boundary: Self.boundary, in: Self.calendar) == example.missed)
    }

    @Test func missedCountsDaysAcrossTheClocksGoingBack() throws {
        // The clocks go back in London on 25 October 2026.
        finished(at: moment(-6, 15))
        let firstLaunch = moment(-100, 9)
        let fourteenth = Self.today.adding(days: 8)
        #expect(
            !WeeklyReview.isMissed(
                try records(), firstLaunch: firstLaunch, now: moment(0, 3, 59, from: fourteenth), boundary: Self.boundary, in: Self.calendar))
        #expect(
            WeeklyReview.isMissed(
                try records(), firstLaunch: firstLaunch, now: moment(0, 4, from: fourteenth), boundary: Self.boundary, in: Self.calendar))
    }

    // MARK: The reminder

    func reminders(_ reminder: ReviewReminder = ReviewReminder(), now: Date) throws -> [Date] {
        WeeklyReview.reminders(try records(), reminder: reminder, now: now, boundary: Self.boundary, in: Self.calendar)
    }

    /// Fridays from today, a Tuesday.
    func friday(_ week: Int, _ hour: Int = 15) -> Date { moment(3 + 7 * week, hour) }

    @Test func remindersComeEachReviewDayAtItsTimeForFourWeeks() throws {
        #expect(try reminders(now: moment(0, 10)) == (0..<4).map { friday($0) })
    }

    @Test func remindersKeepTheirTimeAcrossTheClocksChanging() throws {
        // The clocks go back in London on 25 October 2026, between the first two Fridays.
        let dates = try reminders(now: moment(0, 10))
        for date in dates {
            #expect(Self.calendar.component(.hour, from: date) == 15 && Self.calendar.component(.minute, from: date) == 0)
            #expect(Self.calendar.component(.weekday, from: date) == 6)
        }
        #expect(Set(dates.map { Self.calendar.timeZone.secondsFromGMT(for: $0) }).count == 2)
    }

    @Test func aReminderTodayComesOnlyBeforeItsTime() throws {
        #expect(try reminders(now: friday(0, 14)).first == friday(0))
        #expect(try reminders(now: friday(0, 15)).first == friday(1))
    }

    @Test func theDayAndTimeComeFromTheSettings() throws {
        let sunday = ReviewReminder(weekday: 1, time: 9 * 60 + 30)
        #expect(try reminders(sunday, now: moment(0, 10)).first == moment(5, 9, 30))
    }

    struct SkipCase: CustomTestStringConvertible, Sendable {
        let note: String
        /// When a review was finished, in days and hours from this week's Friday.
        let finished: (days: Int, hour: Int)
        let skipsFriday: Bool
        var testDescription: String { note }
    }

    @Test(arguments: [
        SkipCase(note: "finished the day before", finished: (-1, 16), skipsFriday: true),
        SkipCase(note: "finished earlier on the day", finished: (0, 9), skipsFriday: true),
        SkipCase(note: "finished at 1 a.m. on the day, which was the day before's", finished: (0, 1), skipsFriday: true),
        SkipCase(note: "finished two days before", finished: (-2, 16), skipsFriday: false),
        SkipCase(note: "finished at 1 a.m. the day before, two days by the boundary", finished: (-1, 1), skipsFriday: false),
    ])
    func aReviewJustBeforeSkipsTheReminder(_ example: SkipCase) throws {
        finished(at: moment(3 + example.finished.days, example.finished.hour))
        let expected = example.skipsFriday ? (1...4).map { friday($0) } : (0..<4).map { friday($0) }
        #expect(try reminders(now: moment(0, 10)) == expected)
    }

    @Test func noReminderWhileAReviewIsOpenOrWhenItsOff() throws {
        #expect(try reminders(ReviewReminder(isOn: false), now: moment(0, 10)).isEmpty)
        WeeklyReview.start(in: context, at: moment(-8, 10))
        #expect(try reminders(now: moment(0, 10)).isEmpty)
    }

    @Test func theRemindersAreNotificationsWithNoItem() throws {
        let planned = NotificationPlan.reviewReminders(
            try records(), reminder: ReviewReminder(), now: moment(0, 10), boundary: Self.boundary, in: Self.calendar)
        #expect(planned.count == 4)
        #expect(planned.allSatisfy { $0.itemID == nil && $0.trigger == .weeklyReview && $0.title == "Weekly Review" })
        #expect(planned.first?.id == "weeklyReview-2026-10-23")
    }

    // MARK: Actions and Agenda in review mode

    func action(_ title: String, changed days: Int, hour: Int = 12, _ change: (Item) -> Void = { _ in }) -> Item {
        let item = Item(title: title, bucket: .action)
        context.insert(item)
        change(item)
        item.modifiedAt = moment(days, hour)
        return item
    }

    @Test func actionsUnchangedForTwoWeeksOldestFirst() throws {
        let items = [
            action("Changed 13 days ago", changed: -13),
            action("Changed 14 days ago", changed: -14),
            action("Changed at 2 a.m. 13 days ago, by the boundary 14", changed: -13, hour: 2),
            action("Changed 40 days ago", changed: -40),
            action("Waiting, not an action", changed: -30) { $0.bucket = .waiting },
            action("Done long ago", changed: -30) {
                $0.status = .done
                $0.completedAt = self.moment(-30, 12)
            },
            action("Hidden until tomorrow", changed: -30) { $0.hideUntil = Self.today.adding(days: 1).storedDate },
            action("Starts tomorrow", changed: -30) { $0.scheduledDate = Self.today.adding(days: 1).storedDate },
        ]
        let shown = ActionsList.unchanged(items, today: Self.today, boundary: Self.boundary, in: Self.calendar, doneSince: moment(0, 4))
        #expect(shown.map(\.title) == ["Changed 40 days ago", "Changed 14 days ago", "Changed at 2 a.m. 13 days ago, by the boundary 14"])
        #expect(
            shown.map { ActionsList.daysUnchanged($0, today: Self.today, boundary: Self.boundary, in: Self.calendar) } == [40, 14, 14])
    }

    @Test func aStalledProjectUnchangedForTwoWeeksIsAmongThem() throws {
        let project = action("Kitchen refit", changed: -20)
        let done = action("Measure up", changed: -21) {
            $0.status = .done
            $0.completedAt = self.moment(-21, 12)
        }
        done.parent = project
        let shown = ActionsList.unchanged([project, done], today: Self.today, boundary: Self.boundary, in: Self.calendar, doneSince: moment(0, 4))
        #expect(shown.map(\.title) == ["Kitchen refit"])
    }

    @Test func agendaAheadHasFourWeeksUnderTheirStops() {
        let day = { (days: Int) in Self.today.adding(days: days).storedDate }
        func item(_ title: String, _ change: (Item) -> Void) -> Item {
            let item = Item(title: title, bucket: .action)
            context.insert(item)
            change(item)
            return item
        }
        let items = [
            item("Overdue") { $0.dueDate = day(-2) },
            item("Starts today") { $0.scheduledDate = day(0) },
            item("Starts Thursday") { $0.scheduledDate = day(2) },
            item("Due next week") { $0.dueDate = day(7) },
            item("Starts in four weeks less a day") { $0.scheduledDate = day(27) },
            item("Starts in four weeks") { $0.scheduledDate = day(28) },
        ]
        let stops = Timeline.layouts(today: Self.today, weekStart: 2).last ?? []
        let placements = Timeline.placements(items, today: Self.today, doneSince: nil)
        let ahead = Timeline.ahead(stops, placements, today: Self.today)
        #expect(ahead.map(\.stop.kind) == [.today, .day, .nextWeek, .month])
        #expect(
            ahead.map { $0.items.map(\.title) } == [
                ["Starts today", "Overdue"], ["Starts Thursday"], ["Due next week"], ["Starts in four weeks less a day"],
            ])
    }
}
