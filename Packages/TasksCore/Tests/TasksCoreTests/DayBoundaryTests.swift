import Foundation
import Testing

@testable import TasksCore

struct DayBoundaryTests {
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    static func moment(_ zone: String, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    struct DayCase: CustomTestStringConvertible, Sendable {
        let zone: String
        let now: Date
        let minutes: Int
        let day: LocalDate
        let label: String
        var testDescription: String { label }
    }

    @Test(arguments: [
        DayCase(zone: "Europe/London", now: moment("Europe/London", 2026, 10, 21, 12), minutes: 240, day: LocalDate(2026, 10, 21), label: "midday"),
        DayCase(
            zone: "Europe/London", now: moment("Europe/London", 2026, 10, 22, 0, 30), minutes: 240, day: LocalDate(2026, 10, 21),
            label: "after midnight"),
        DayCase(
            zone: "Europe/London", now: moment("Europe/London", 2026, 10, 22, 3, 59), minutes: 240, day: LocalDate(2026, 10, 21),
            label: "a minute before 04:00"),
        DayCase(zone: "Europe/London", now: moment("Europe/London", 2026, 10, 22, 4), minutes: 240, day: LocalDate(2026, 10, 22), label: "at 04:00"),
        DayCase(
            zone: "Europe/London", now: moment("Europe/London", 2026, 10, 22, 0, 30), minutes: 0, day: LocalDate(2026, 10, 22),
            label: "a midnight boundary"),
        DayCase(
            zone: "America/New_York", now: moment("America/New_York", 2026, 11, 1, 1, 30), minutes: 240, day: LocalDate(2026, 10, 31),
            label: "inside the hour the clocks go back"),
        DayCase(
            zone: "America/New_York", now: moment("America/New_York", 2026, 11, 1, 3, 59), minutes: 240, day: LocalDate(2026, 10, 31),
            label: "before 04:00 on the day the clocks go back"),
        DayCase(
            zone: "America/New_York", now: moment("America/New_York", 2026, 11, 1, 4), minutes: 240, day: LocalDate(2026, 11, 1),
            label: "04:00 on the day the clocks go back"),
        DayCase(
            zone: "America/New_York", now: moment("America/New_York", 2027, 3, 14, 3, 59), minutes: 240, day: LocalDate(2027, 3, 13),
            label: "before 04:00 on the day the clocks go forward"),
        DayCase(
            zone: "America/New_York", now: moment("America/New_York", 2027, 3, 14, 4), minutes: 240, day: LocalDate(2027, 3, 14),
            label: "04:00 on the day the clocks go forward"),
        DayCase(
            zone: "America/New_York", now: moment("America/New_York", 2027, 3, 14, 3), minutes: 150, day: LocalDate(2027, 3, 13),
            label: "a 02:30 boundary in the gap, at 03:00"),
        DayCase(
            zone: "America/New_York", now: moment("America/New_York", 2027, 3, 14, 3, 30), minutes: 150, day: LocalDate(2027, 3, 14),
            label: "a 02:30 boundary in the gap, at 03:30"),
    ])
    func theDayStartsAtTheBoundary(_ example: DayCase) {
        #expect(DayBoundary(minutes: example.minutes).day(at: example.now, in: Self.calendar(example.zone)) == example.day)
    }

    @Test func theDayTheClocksGoBackInIsTwentyFiveHoursLong() {
        let calendar = Self.calendar("America/New_York")
        let boundary = DayBoundary()
        let start = boundary.start(of: LocalDate(2026, 10, 31), in: calendar)
        let next = boundary.nextStart(after: Self.moment("America/New_York", 2026, 10, 31, 12), in: calendar)
        #expect(next.timeIntervalSince(start) == 25 * 3600)
        #expect(boundary.day(at: next, in: calendar) == LocalDate(2026, 11, 1))
    }

    @Test func theNextStartBeforeTheBoundaryIsTheSameMorning() {
        let calendar = Self.calendar("Europe/London")
        let next = DayBoundary().nextStart(after: Self.moment("Europe/London", 2026, 10, 22, 2), in: calendar)
        #expect(next == Self.moment("Europe/London", 2026, 10, 22, 4))
    }

    @Test(arguments: [(-5, 0), (240, 240), (2000, 1439)])
    func minutesStayInsideTheDay(given: Int, kept: Int) {
        #expect(DayBoundary(minutes: given).minutes == kept)
    }
}
