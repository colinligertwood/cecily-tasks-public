import Foundation
import Testing

@testable import TasksCore

struct RepeatRuleTests {
    struct AfterCase: CustomTestStringConvertible, Sendable {
        let name: String
        let value: Int
        let unit: RepeatRule.Unit
        let closedOn: LocalDate
        let expected: LocalDate
        var testDescription: String { name }
    }

    @Test(arguments: [
        AfterCase(name: "3 days after done", value: 3, unit: .day, closedOn: LocalDate(2026, 10, 30), expected: LocalDate(2026, 11, 2)),
        AfterCase(name: "2 weeks after done", value: 2, unit: .week, closedOn: LocalDate(2026, 10, 20), expected: LocalDate(2026, 11, 3)),
        AfterCase(name: "1 month after done", value: 1, unit: .month, closedOn: LocalDate(2026, 10, 20), expected: LocalDate(2026, 11, 20)),
        AfterCase(name: "1 month after 31 January", value: 1, unit: .month, closedOn: LocalDate(2027, 1, 31), expected: LocalDate(2027, 2, 28)),
        AfterCase(
            name: "1 month after 31 January, leap year", value: 1, unit: .month, closedOn: LocalDate(2028, 1, 31), expected: LocalDate(2028, 2, 29)),
        AfterCase(name: "1 month after 31 March", value: 1, unit: .month, closedOn: LocalDate(2027, 3, 31), expected: LocalDate(2027, 4, 30)),
        AfterCase(name: "1 month after 31 December", value: 1, unit: .month, closedOn: LocalDate(2026, 12, 31), expected: LocalDate(2027, 1, 31)),
        AfterCase(name: "13 months after done", value: 13, unit: .month, closedOn: LocalDate(2026, 12, 15), expected: LocalDate(2028, 1, 15)),
        AfterCase(name: "1 year after 29 February", value: 1, unit: .year, closedOn: LocalDate(2028, 2, 29), expected: LocalDate(2029, 2, 28)),
        AfterCase(name: "4 years after 29 February", value: 4, unit: .year, closedOn: LocalDate(2028, 2, 29), expected: LocalDate(2032, 2, 29)),
        AfterCase(
            name: "1 day after 28 February, leap year", value: 1, unit: .day, closedOn: LocalDate(2028, 2, 28), expected: LocalDate(2028, 2, 29)),
        AfterCase(name: "1 day after 31 December", value: 1, unit: .day, closedOn: LocalDate(2026, 12, 31), expected: LocalDate(2027, 1, 1)),
        AfterCase(
            name: "1 week across the end of daylight saving", value: 1, unit: .week, closedOn: LocalDate(2026, 10, 28),
            expected: LocalDate(2026, 11, 4)),
    ])
    func afterCompletionCountsFromTheDayItsDone(_ example: AfterCase) {
        let rule = RepeatRule(.afterCompletion(value: example.value, unit: example.unit))
        let next = rule.nextDate(after: LocalDate(2026, 1, 1), closedOn: example.closedOn, seriesStart: LocalDate(2026, 1, 1))
        #expect(next == example.expected)
    }

    @Test func aScheduleDoneEarlyMovesToTheFollowingDate() throws {
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=MONTHLY;BYDAY=-1FR")))
        let next = rule.nextDate(after: LocalDate(2026, 10, 30), closedOn: LocalDate(2026, 10, 25), seriesStart: LocalDate(2026, 10, 20))
        #expect(next == LocalDate(2026, 11, 27))
    }

    @Test func aScheduleDoneLateSkipsTheDatesThatPassedMeanwhile() throws {
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=TU")))
        let next = rule.nextDate(after: LocalDate(2026, 10, 20), closedOn: LocalDate(2026, 11, 5), seriesStart: LocalDate(2026, 10, 20))
        #expect(next == LocalDate(2026, 11, 10))
    }

    @Test func aScheduleDoneOnAnotherOccurrenceMovesPastIt() throws {
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;BYDAY=TU")))
        let next = rule.nextDate(after: LocalDate(2026, 10, 20), closedOn: LocalDate(2026, 10, 27), seriesStart: LocalDate(2026, 10, 20))
        #expect(next == LocalDate(2026, 11, 3))
    }

    @Test func aScheduleKeepsItsCountFromTheSeriesStart() throws {
        let rule = RepeatRule(.schedule(try Recurrence(rrule: "FREQ=WEEKLY;COUNT=3")))
        let start = LocalDate(2026, 10, 20)
        #expect(rule.nextDate(after: LocalDate(2026, 10, 27), closedOn: LocalDate(2026, 10, 27), seriesStart: start) == LocalDate(2026, 11, 3))
        #expect(rule.nextDate(after: LocalDate(2026, 11, 3), closedOn: LocalDate(2026, 11, 3), seriesStart: start) == nil)
    }

    @Test func theEndDateStopsTheRepeat() {
        let rule = RepeatRule(.afterCompletion(value: 1, unit: .week), endDate: LocalDate(2026, 11, 1))
        #expect(
            rule.nextDate(after: LocalDate(2026, 10, 20), closedOn: LocalDate(2026, 10, 20), seriesStart: LocalDate(2026, 10, 20))
                == LocalDate(2026, 10, 27))
        #expect(rule.nextDate(after: LocalDate(2026, 10, 27), closedOn: LocalDate(2026, 10, 27), seriesStart: LocalDate(2026, 10, 20)) == nil)
    }

    @Test func theRemainingCountRunsDown() {
        var rule = RepeatRule(.afterCompletion(value: 1, unit: .day), remainingCount: 2)
        var dates: [LocalDate] = []
        var day = LocalDate(2026, 10, 20)
        while let next = rule.nextDate(after: day, closedOn: day, seriesStart: LocalDate(2026, 10, 20)) {
            dates.append(next)
            day = next
            rule = rule.advanced()
        }
        #expect(dates == [LocalDate(2026, 10, 21), LocalDate(2026, 10, 22)])
        #expect(rule.remainingCount == 0)
    }

    @Test func noLimitStaysUnlimited() {
        let rule = RepeatRule(.afterCompletion(value: 1, unit: .day))
        #expect(rule.advanced().remainingCount == nil)
    }

    @Test(arguments: [(0, nil as LocalDate?), (1, LocalDate(2026, 10, 30)), (3, LocalDate(2026, 10, 28)), (7, LocalDate(2026, 10, 24))])
    func showEarlyHidesTheCopyUntilDaysBefore(daysBefore: Int, expected: LocalDate?) {
        let rule = RepeatRule(.afterCompletion(value: 1, unit: .month), showDaysBefore: daysBefore)
        #expect(rule.hideUntil(for: LocalDate(2026, 10, 31)) == expected)
    }

    @Test func showEarlyCrossesAMonthAndYearStart() {
        let rule = RepeatRule(.afterCompletion(value: 1, unit: .month), showDaysBefore: 3)
        #expect(rule.hideUntil(for: LocalDate(2027, 1, 2)) == LocalDate(2026, 12, 30))
        #expect(rule.hideUntil(for: LocalDate(2028, 3, 1)) == LocalDate(2028, 2, 27))
    }
}
