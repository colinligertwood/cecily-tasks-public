import Foundation
import Testing

@testable import TasksCore

struct DaylightSavingTests {
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    struct ZoneCase: CustomTestStringConvertible, Sendable {
        let zone: String
        let rule: String
        let start: LocalDate
        /// The day the clocks change, which some pair of occurrences must straddle.
        let change: LocalDate
        var testDescription: String { "\(zone) \(rule) across \(change)" }
    }

    @Test(arguments: [
        ZoneCase(zone: "America/New_York", rule: "FREQ=DAILY", start: LocalDate(2026, 10, 29), change: LocalDate(2026, 11, 1)),
        ZoneCase(zone: "America/New_York", rule: "FREQ=DAILY", start: LocalDate(2027, 3, 12), change: LocalDate(2027, 3, 14)),
        ZoneCase(zone: "Europe/London", rule: "FREQ=WEEKLY;BYDAY=FR", start: LocalDate(2026, 10, 16), change: LocalDate(2026, 10, 25)),
        ZoneCase(zone: "Europe/London", rule: "FREQ=WEEKLY", start: LocalDate(2027, 3, 21), change: LocalDate(2027, 3, 28)),
        ZoneCase(zone: "Australia/Sydney", rule: "FREQ=MONTHLY;BYMONTHDAY=1", start: LocalDate(2026, 9, 1), change: LocalDate(2026, 10, 4)),
        ZoneCase(zone: "Australia/Sydney", rule: "FREQ=MONTHLY;BYDAY=1SU", start: LocalDate(2027, 3, 1), change: LocalDate(2027, 4, 4)),
        ZoneCase(zone: "Australia/Lord_Howe", rule: "FREQ=DAILY", start: LocalDate(2026, 10, 2), change: LocalDate(2026, 10, 4)),
        ZoneCase(zone: "Europe/Berlin", rule: "FREQ=DAILY;INTERVAL=2", start: LocalDate(2026, 10, 23), change: LocalDate(2026, 10, 25)),
    ])
    func occurrencesKeepTheirTimeOfDayWhenTheClocksChange(_ example: ZoneCase) throws {
        let calendar = Self.calendar(example.zone)
        let days = try Recurrence(rrule: example.rule).occurrences(from: example.start, limit: 4)
        let moments = days.map { $0.date(in: calendar, hour: 9) }
        for (day, moment) in zip(days, moments) {
            #expect(LocalDate(moment, in: calendar) == day)
            #expect(calendar.component(.hour, from: moment) == 9)
            #expect(calendar.component(.minute, from: moment) == 0)
        }
        #expect(days.first! <= example.change && example.change <= days.last!)
        let offsets = Set(moments.map { calendar.timeZone.secondsFromGMT(for: $0) })
        #expect(offsets.count == 2, "the occurrences should fall on both sides of the change")
    }

    @Test func aTimeInTheSpringGapMovesForward() throws {
        let calendar = Self.calendar("America/New_York")
        let changes = try Recurrence(rrule: "FREQ=YEARLY;BYMONTH=3;BYDAY=2SU").occurrences(from: LocalDate(2027, 1, 1), limit: 4)
        #expect(changes == [LocalDate(2027, 3, 14), LocalDate(2028, 3, 12), LocalDate(2029, 3, 11), LocalDate(2030, 3, 10)])
        for day in changes {
            let moment = day.date(in: calendar, hour: 2, minute: 30)
            #expect(LocalDate(moment, in: calendar) == day)
            #expect(calendar.component(.hour, from: moment) == 3)
            #expect(calendar.component(.minute, from: moment) == 30)
        }
    }

    @Test func aTimeInTheAutumnOverlapKeepsItsDayAndTime() throws {
        let calendar = Self.calendar("America/New_York")
        let changes = try Recurrence(rrule: "FREQ=YEARLY;BYMONTH=11;BYDAY=1SU").occurrences(from: LocalDate(2026, 1, 1), limit: 3)
        #expect(changes == [LocalDate(2026, 11, 1), LocalDate(2027, 11, 7), LocalDate(2028, 11, 5)])
        for day in changes {
            let moment = day.date(in: calendar, hour: 1, minute: 30)
            #expect(LocalDate(moment, in: calendar) == day)
            #expect(calendar.component(.hour, from: moment) == 1)
        }
    }

    @Test func theDayOfAMomentDependsOnTheTimeZone() {
        let moment = Date(timeIntervalSince1970: 1_792_884_600)  // 2026-10-24 23:30 UTC
        #expect(LocalDate(moment, in: Self.calendar("UTC")) == LocalDate(2026, 10, 24))
        #expect(LocalDate(moment, in: Self.calendar("Europe/London")) == LocalDate(2026, 10, 25))
        #expect(LocalDate(moment, in: Self.calendar("America/Los_Angeles")) == LocalDate(2026, 10, 24))
    }

    @Test func dayArithmeticIgnoresTheClocks() {
        let change = LocalDate(2026, 10, 25)
        #expect(change.adding(days: 1) == LocalDate(2026, 10, 26))
        #expect(change.adding(days: -1) == LocalDate(2026, 10, 24))
        #expect(LocalDate(2026, 3, 1).days(to: LocalDate(2026, 11, 1)) == 245)
        #expect(LocalDate(2028, 1, 1).days(to: LocalDate(2029, 1, 1)) == 366)
    }

    @Test func aRepeatShowsTheSameDayInEveryTimeZone() throws {
        let days = try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=MO").occurrences(from: LocalDate(2026, 10, 20), limit: 3)
        for zone in ["Pacific/Auckland", "Pacific/Honolulu", "Asia/Kolkata", "America/St_Johns"] {
            let calendar = Self.calendar(zone)
            #expect(days.map { LocalDate($0.date(in: calendar, hour: 0), in: calendar) } == days)
            #expect(days.allSatisfy { calendar.component(.weekday, from: $0.date(in: calendar, hour: 12)) == 2 })
        }
    }
}
