import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// The Inbox's groups by when things came in, and when it was last emptied.
@MainActor
struct InboxListTests {
    /// Tuesday 27 October 2026; weeks start on Monday.
    static let today = LocalDate(2026, 10, 27)
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        return calendar
    }()
    static let boundary = DayBoundary()
    let context = ModelContext(try! TasksSchema.container(at: nil))

    func item(captured day: LocalDate, hour: Int = 12) -> Item {
        let item = Item(title: "Call Sam")
        item.createdAt = day.date(in: Self.calendar, hour: hour)
        context.insert(item)
        return item
    }

    @Test(arguments: [
        (0, 12, InboxList.Period.today), (0, 5, .today), (1, 3, .today), (-1, 12, .yesterday), (0, 3, .yesterday),
        (-2, 12, .earlier), (-7, 12, .earlier),
    ])
    func eachItemIsInTheGroupOfTheDayItCameIn(daysAgo: Int, hour: Int, period: InboxList.Period) {
        // Tuesday: the week started yesterday, so the day before yesterday is already Earlier.
        #expect(
            InboxList.period(
                of: item(captured: Self.today.adding(days: daysAgo), hour: hour), today: Self.today, boundary: Self.boundary, in: Self.calendar)
                == period)
    }

    @Test func thisWeekIsTheDaysBeforeYesterdaySinceTheWeekStarted() {
        let friday = LocalDate(2026, 10, 30)
        func period(_ day: LocalDate) -> InboxList.Period {
            InboxList.period(of: item(captured: day), today: friday, boundary: Self.boundary, in: Self.calendar)
        }
        #expect(period(LocalDate(2026, 10, 28)) == .thisWeek, "Wednesday")
        #expect(period(LocalDate(2026, 10, 26)) == .thisWeek, "Monday, the week's first day")
        #expect(period(LocalDate(2026, 10, 25)) == .earlier, "Sunday, last week")
    }

    @Test(arguments: [
        (0, 9, "Emptied this morning"), (0, 14, "Emptied this afternoon"), (0, 20, "Emptied this evening"), (-1, 12, "Emptied yesterday"),
        (-6, 12, "Emptied on Wednesday"), (-15, 12, "Emptied on 12 October"),
    ])
    func whenItWasLastEmptied(daysAgo: Int, hour: Int, words: String) {
        let moment = Self.today.adding(days: daysAgo).date(in: Self.calendar, hour: hour)
        let now = Self.today.date(in: Self.calendar, hour: 21)
        #expect(InboxList.emptied(at: moment, now: now, boundary: Self.boundary, in: Self.calendar) == words)
    }
}
