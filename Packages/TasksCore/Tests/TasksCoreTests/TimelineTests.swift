import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct TimelineTests {
    /// A Monday.
    static let today = LocalDate(2026, 10, 26)
    static let monday = 2
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
    }

    func item(
        _ title: String, _ bucket: Bucket = .action, starts: Int? = nil, hour: Int? = nil, due: Int? = nil, followUp: Int? = nil,
        hiddenUntil: Int? = nil, order: Double = 0
    ) -> Item {
        let item = Item(title: title, bucket: bucket)
        let day = { (days: Int) in Self.today.adding(days: days) }
        item.scheduledDate = starts.map { day($0).storedDate }
        item.scheduledTime = starts.flatMap { starts in hour.map { day(starts).date(in: .current, hour: $0) } }
        item.dueDate = due.map { day($0).storedDate }
        item.followUpDate = followUp.map { day($0).storedDate }
        item.hideUntil = hiddenUntil.map { day($0).storedDate }
        item.sortOrder = order
        context.insert(item)
        return item
    }

    func stop(_ kind: TimelineStop.Kind, _ first: LocalDate, _ last: LocalDate?) -> TimelineStop {
        TimelineStop(kind: kind, first: first, last: last)
    }

    func widest(today: LocalDate = Self.today, weekStart: Int = Self.monday) -> [TimelineStop] {
        Timeline.layouts(today: today, weekStart: weekStart).last ?? []
    }

    /// The stop's parts as titles, leaving out empty ones.
    func parts(_ items: [Item], in kind: TimelineStop.Kind = .today, first: Int = 0, doneSince: Date? = nil, showsHidden: Bool = false)
        -> [TimelinePlacement.Part: [String]]
    {
        let placements = Timeline.placements(items, today: Self.today, doneSince: doneSince, showsHidden: showsHidden)
        let stop = widest().first { $0.kind == kind && $0.first == Self.today.adding(days: first) }!
        let parts = Timeline.parts(of: stop, placements, today: Self.today)
        let all: [(TimelinePlacement.Part, [Item])] = [(.starts, parts.starts), (.due, parts.due), (.followUp, parts.followUp)]
        return Dictionary(uniqueKeysWithValues: all.filter { !$0.1.isEmpty }.map { ($0.0, $0.1.map(\.title)) })
    }

    // MARK: Stops

    @Test func onAMondayTheWeeksDaysThisWeekNextWeekThenWholeMonths() {
        let d = { LocalDate(2026, $0, $1) }
        let expected =
            [stop(.today, d(10, 26), d(10, 26))] + (27...31).map { stop(.day, d(10, $0), d(10, $0)) } + [stop(.day, d(11, 1), d(11, 1))]
            + [stop(.thisWeek, d(10, 26), d(11, 1)), stop(.nextWeek, d(11, 2), d(11, 8)), stop(.month, d(11, 1), d(11, 30))]
            + [stop(.month, d(12, 1), d(12, 31))]
        #expect(Array(widest().prefix(11)) == expected)
        #expect(widest().last == stop(.later, LocalDate(2027, 11, 1), nil))
    }

    @Test(arguments: [
        // Today, the six days after it, next week's first day, and the first month stop's: the
        // month after next week ends in, from its first day or today.
        (LocalDate(2026, 10, 31), 2, (1...6).map { LocalDate(2026, 11, $0) }, LocalDate(2026, 11, 2), LocalDate(2026, 11, 1)),
        (LocalDate(2026, 11, 1), 2, (2...7).map { LocalDate(2026, 11, $0) }, LocalDate(2026, 11, 2), LocalDate(2026, 11, 1)),
        (
            LocalDate(2026, 10, 26), 1, (27...31).map { LocalDate(2026, 10, $0) } + [LocalDate(2026, 11, 1)], LocalDate(2026, 11, 1),
            LocalDate(2026, 11, 1)
        ),
        (LocalDate(2026, 10, 31), 1, (1...6).map { LocalDate(2026, 11, $0) }, LocalDate(2026, 11, 1), LocalDate(2026, 11, 1)),
        (LocalDate(2026, 10, 5), 2, (6...11).map { LocalDate(2026, 10, $0) }, LocalDate(2026, 10, 12), LocalDate(2026, 10, 5)),
        (LocalDate(2026, 11, 23), 2, (24...29).map { LocalDate(2026, 11, $0) }, LocalDate(2026, 11, 30), LocalDate(2026, 12, 1)),
    ])
    func eachWeekdayHasSixDaysThenNextWeek(today: LocalDate, weekStart: Int, days: [LocalDate], nextWeek: LocalDate, month: LocalDate) {
        let stops = widest(today: today, weekStart: weekStart)
        #expect(stops.filter { $0.kind == .day }.map(\.first) == days)
        let next = stops.first { $0.kind == .nextWeek }
        #expect(next?.first == nextWeek && next?.last == nextWeek.adding(days: 6))
        let first = stops.first { $0.kind == .month }
        #expect(first?.first == month)
        #expect(first?.last.map { $0.month == month.month && $0.isLastDayOfMonth } == true)
    }

    @Test func monthsCrossTheYearsEnd() {
        let months = widest(today: LocalDate(2026, 12, 14)).filter { $0.kind == .month }
        #expect(months.prefix(3).map(\.first) == [LocalDate(2026, 12, 14), LocalDate(2027, 1, 1), LocalDate(2027, 2, 1)])
        #expect(months.prefix(3).map(\.last) == [LocalDate(2026, 12, 31), LocalDate(2027, 1, 31), LocalDate(2027, 2, 28)])
    }

    @Test func monthsFoldFirstThenTheWeeksDays() throws {
        let layouts = Timeline.layouts(today: Self.today, weekStart: Self.monday)
        #expect(layouts.count == 2 + Timeline.mostMonths)
        #expect(layouts[0].map(\.kind) == [.today, .thisWeek, .nextWeek, .later])
        #expect(layouts[0][1].first == Self.today && layouts[0][1].last == LocalDate(2026, 11, 1))
        #expect(layouts[1].map(\.kind) == [.today] + Array(repeating: .day, count: 6) + [.thisWeek, .nextWeek, .later])
        for (index, layout) in layouts.enumerated().dropFirst(2) {
            #expect(layout.filter { $0.kind == .month }.count == index - 1)
        }
        let saturday = Timeline.layouts(today: LocalDate(2026, 10, 31), weekStart: Self.monday)
        #expect(saturday[0].map(\.kind) == [.today, .thisWeek, .nextWeek, .later])
        #expect(saturday[1].map(\.kind) == [.today] + Array(repeating: .day, count: 6) + [.thisWeek, .nextWeek, .later])
        let sunday = Timeline.layouts(today: LocalDate(2026, 11, 1), weekStart: Self.monday)
        #expect(sunday[0].map(\.kind) == [.today, .nextWeek, .later] && sunday.count == 2 + Timeline.mostMonths)
        #expect(sunday[1].map(\.kind) == [.today] + Array(repeating: .day, count: 6) + [.nextWeek, .later])
    }

    @Test(arguments: [LocalDate(2026, 10, 26), LocalDate(2026, 10, 31), LocalDate(2026, 11, 1), LocalDate(2026, 12, 30)])
    func everyDayHasAStopThatsNotThisWeekUnlessItsFolded(today: LocalDate) {
        for layout in Timeline.layouts(today: today, weekStart: Self.monday) {
            let foldsTheDays = !layout.contains { $0.kind == .day }
            for offset in -30...500 {
                let day = today.adding(days: offset)
                let stop = Timeline.stop(for: day, in: layout)
                #expect(stop?.contains(day) == true, "\(day) in \(layout.map(\.id))")
                #expect(stop?.kind != .thisWeek || (foldsTheDays && offset > 0), "\(day) on This Week")
                if let week = layout.first(where: { $0.kind == .thisWeek }) {
                    #expect(week.contains(day) == (offset >= 0 && day <= week.last!), "\(day) in This Week")
                }
            }
        }
    }

    // MARK: Parts

    @Test func todayHasTimesFirstThenTheRestThenEarlierDaysOldestFirst() {
        let items = [
            item("Yesterday", starts: -1), item("Last week", starts: -7), item("Untimed", starts: 0), item("Afternoon", starts: 0, hour: 15),
            item("Morning", starts: 0, hour: 9), item("Tomorrow", starts: 1),
        ]
        #expect(parts(items) == [.starts: ["Morning", "Afternoon", "Untimed", "Last week", "Yesterday"]])
    }

    @Test func dueAndFollowUpAreOldestFirstWithOverdueInToday() {
        let items = [
            item("Today", due: 0), item("Last week", .waiting, due: -7), item("Yesterday", .inbox, due: -1), item("Tomorrow", due: 1),
            item("Chase", .waiting, followUp: 0), item("Chase earlier", .waiting, followUp: -3),
        ]
        #expect(parts(items) == [.due: ["Last week", "Yesterday", "Today"], .followUp: ["Chase earlier", "Chase"]])
        #expect(parts(items, in: .day, first: 1) == [.due: ["Tomorrow"]])
    }

    @Test func thisWeekHasTodayAndTheWeeksDays() {
        let items = [item("Today", starts: 0), item("Overdue", due: -2), item("Sunday", starts: 6), item("Next Monday", starts: 7)]
        let placements = Timeline.placements(items, today: Self.today, doneSince: nil)
        let week = Timeline.layouts(today: Self.today, weekStart: Self.monday)[0][1]
        let parts = Timeline.parts(of: week, placements, today: Self.today)
        #expect(parts.starts.map(\.title) == ["Today", "Sunday"] && parts.due.map(\.title) == ["Overdue"])
    }

    @Test func aLaterStopHasItsDaysInOrder() {
        let items = [item("Sunday", starts: 6), item("Friday", starts: 4), item("Friday morning", starts: 4, hour: 8), item("Due Wednesday", due: 2)]
        let placements = Timeline.placements(items, today: Self.today, doneSince: nil)
        let week = Timeline.layouts(today: Self.today, weekStart: Self.monday)[0][1]
        let parts = Timeline.parts(of: week, placements, today: Self.today)
        #expect(parts.starts.map(\.title) == ["Friday morning", "Friday", "Sunday"] && parts.due.map(\.title) == ["Due Wednesday"])
    }

    @Test(arguments: [Bucket.inbox, .waiting, .someday, .reference])
    func onlyActionsStart(bucket: Bucket) {
        #expect(parts([item("Elsewhere", bucket, starts: 0)]).isEmpty)
    }

    @Test func onlyWaitingItemsFollowUp() {
        #expect(parts([item("Not waiting", followUp: 0)]).isEmpty)
    }

    @Test func anItemIsOnceOnItsEarliestDate() {
        let items = [
            item("Starts then due", starts: 1, due: 9), item("Due then starts", starts: 3, due: 1), item("Same day", starts: 1, due: 1, order: 1),
            item("Follow-up first", .waiting, due: 5, followUp: 1),
        ]
        #expect(
            parts(items, in: .day, first: 1) == [
                .starts: ["Starts then due", "Same day"], .due: ["Due then starts"], .followUp: ["Follow-up first"],
            ])
        #expect(parts(items, in: .day, first: 3).isEmpty && parts(items, in: .day, first: 5).isEmpty)
    }

    @Test func dueTodayOrEarlierIsUnderDueWhateverStartedFirst() {
        let items = [
            item("Started earlier, due tomorrow", starts: -1, due: 1), item("Started earlier, due today", starts: -2, due: 0),
            item("Started earlier, overdue", starts: -5, due: -1), item("Waiting, overdue", .waiting, due: -2, followUp: -4),
        ]
        #expect(
            parts(items) == [
                .starts: ["Started earlier, due tomorrow"], .due: ["Waiting, overdue", "Started earlier, overdue", "Started earlier, due today"],
            ])
        #expect(parts(items, in: .day, first: 1).isEmpty, "each item is still in one stop")
    }

    @Test func hideUntilIsntADate() {
        let items = [
            item("Back today", .someday, hiddenUntil: 0), item("Hidden, due today", due: 0, hiddenUntil: 2),
            item("Was hidden", due: 0, hiddenUntil: -1, order: 1),
        ]
        #expect(parts(items) == [.due: ["Was hidden"]])
        #expect(parts(items, showsHidden: true) == [.due: ["Hidden, due today", "Was hidden"]])
    }

    @Test func doneTodayStaysAndDoneBeforeGoes() {
        let dayStart = Self.today.date(in: .current, hour: 4)
        let doneToday = item("Done today", starts: -2)
        doneToday.markDone(at: dayStart.addingTimeInterval(60))
        let doneBefore = item("Done before", due: -1)
        doneBefore.markDone(at: dayStart.addingTimeInterval(-60))
        let dropped = item("Dropped", starts: 0)
        dropped.status = .dropped
        #expect(parts([doneToday, doneBefore, dropped], doneSince: dayStart) == [.starts: ["Done today"]])
    }

    @Test func trashedItemsAndThoseUnderGoneTasksAreLeftOut() {
        let trashed = item("Trashed", .trash, due: 0)
        let project = context.insertProject("Dropped project")
        project.status = .dropped
        let inProject = item("In it", starts: 0)
        inProject.parent = project
        let someday = context.insertProject("Someday project")
        someday.bucket = .someday
        let onSomeday = item("Under it", due: 0)
        onSomeday.parent = someday
        #expect(Timeline.placements([trashed, inProject, onSomeday], today: Self.today, doneSince: nil).isEmpty)
    }

    @Test func subtasksArePlacedByTheirOwnDates() {
        let parent = item("Parent", due: 3)
        let subtask = item("Subtask", starts: 0)
        subtask.parent = parent
        let placements = Timeline.placements([parent, subtask], today: Self.today, doneSince: nil)
        #expect(placements.map { "\($0.item.title) \(Self.today.days(to: $0.day))" }.sorted() == ["Parent 3", "Subtask 0"])
    }

    @Test func everyOpenDatedItemIsOnItsStopOnce() {
        let items = (-20...400).flatMap { (days: Int) in
            [item("Due \(days)", due: days), item("Starts \(days)", starts: days), item("Waiting \(days)", .waiting, followUp: days)]
        }
        let placements = Timeline.placements(items, today: Self.today, doneSince: nil)
        #expect(placements.count == items.count)
        for layout in Timeline.layouts(today: Self.today, weekStart: Self.monday) {
            let shown = Timeline.ahead(layout, placements, today: Self.today, days: 1000).flatMap(\.items)
            #expect(shown.count == items.count && Set(shown.map(\.id)).count == items.count)
        }
    }

    @Test func theStopsWithSomethingAreFilled() {
        let placements = Timeline.placements([item("Friday", starts: 4), item("Overdue", due: -2)], today: Self.today, doneSince: nil)
        let layout = Timeline.layouts(today: Self.today, weekStart: Self.monday)[1]
        let filled = Timeline.filled(layout, placements)
        #expect(filled == Set(layout.filter { [.today, .thisWeek].contains($0.kind) || $0.first == Self.today.adding(days: 4) }))
    }

    @Test(arguments: ["Europe/London", "America/New_York", "Australia/Sydney"])
    func whatStartsTomorrowComesInAtTheDaysStartAndNotBefore(zone: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let boundary = DayBoundary()
        // Each zone's change of clocks in autumn 2026 or spring 2027.
        for changeDay in [LocalDate(2026, 10, 25), LocalDate(2026, 11, 1), LocalDate(2026, 10, 4), LocalDate(2027, 3, 28), LocalDate(2027, 4, 4)] {
            let item = item("Tomorrow's", starts: Self.today.days(to: changeDay))
            let start = boundary.start(of: changeDay, in: calendar)
            for (moment, expected) in [(start.addingTimeInterval(-60), false), (start, true)] {
                let today = boundary.day(at: moment, in: calendar)
                let placement = Timeline.placements([item], today: today, doneSince: nil).first
                let stop = placement.flatMap { Timeline.stop(for: $0.day, in: Timeline.layouts(today: today, weekStart: Self.monday)[0]) }
                #expect((stop?.kind == .today) == expected, "\(zone) \(changeDay) \(moment)")
            }
        }
    }
}
