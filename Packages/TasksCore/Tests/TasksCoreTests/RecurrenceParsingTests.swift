import Foundation
import Testing

@testable import TasksCore

struct RecurrenceParsingTests {
    @Test(arguments: OccurrenceTests.cases)
    func everyTableRuleSurvivesARoundTrip(_ example: RuleCase) throws {
        let rule = try Recurrence(rrule: example.rule)
        #expect(try Recurrence(rrule: rule.rrule) == rule)
    }

    @Test(arguments: [
        ("FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1", "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1"),
        ("RRULE:FREQ=WEEKLY;BYDAY=MO,TH;INTERVAL=2", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH"),
        ("freq=monthly;interval=3;byday=2tu", "FREQ=MONTHLY;INTERVAL=3;BYDAY=2TU"),
        ("FREQ=YEARLY;BYMONTHDAY=15;BYMONTH=3", "FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15"),
        ("FREQ=WEEKLY;INTERVAL=6;UNTIL=20261231T235959Z", "FREQ=WEEKLY;INTERVAL=6;UNTIL=20261231"),
        ("FREQ=DAILY;COUNT=10;INTERVAL=1", "FREQ=DAILY;COUNT=10"),
        ("FREQ=WEEKLY;WKST=SU;BYDAY=SU", "FREQ=WEEKLY;BYDAY=SU;WKST=SU"),
        ("FREQ=WEEKLY;WKST=MO", "FREQ=WEEKLY"),
        (" FREQ=MONTHLY;BYMONTHDAY=1,15; ", "FREQ=MONTHLY;BYMONTHDAY=1,15"),
    ])
    func writesRulesInAFixedOrder(input: String, written: String) throws {
        #expect(try Recurrence(rrule: input).rrule == written)
    }

    @Test func readsEachPart() throws {
        let rule = try Recurrence(rrule: "FREQ=YEARLY;INTERVAL=2;BYMONTH=1,7;BYMONTHDAY=-1;BYDAY=-2FR,MO;BYSETPOS=1,-1;WKST=SU;COUNT=4")
        #expect(rule.frequency == .yearly)
        #expect(rule.interval == 2)
        #expect(rule.byMonth == [1, 7])
        #expect(rule.byMonthDay == [-1])
        #expect(rule.byDay == [.init(.friday, -2), .init(.monday)])
        #expect(rule.bySetPosition == [1, -1])
        #expect(rule.weekStart == .sunday)
        #expect(rule.end == .count(4))
    }

    @Test(arguments: [
        ("BYDAY=MO", RecurrenceError.missingFrequency),
        ("", .missingFrequency),
        ("FREQ=HOURLY", .unsupported("FREQ=HOURLY")),
        ("FREQ=MINUTELY", .unsupported("FREQ=MINUTELY")),
        ("FREQ=DAILY;BYHOUR=9", .unsupported("BYHOUR")),
        ("FREQ=YEARLY;BYYEARDAY=100", .unsupported("BYYEARDAY")),
        ("FREQ=YEARLY;BYWEEKNO=20", .unsupported("BYWEEKNO")),
        ("FREQ=DAILY;COUNT=3;UNTIL=20261231", .countAndUntil),
        ("FREQ=FORTNIGHTLY", .invalidValue(part: "FREQ", value: "FORTNIGHTLY")),
        ("FREQ=DAILY;INTERVAL=0", .invalidValue(part: "INTERVAL", value: "0")),
        ("FREQ=DAILY;INTERVAL=two", .invalidValue(part: "INTERVAL", value: "TWO")),
        ("FREQ=WEEKLY;BYDAY=XX", .invalidValue(part: "BYDAY", value: "XX")),
        ("FREQ=MONTHLY;BYDAY=6MO", .invalidValue(part: "BYDAY", value: "6MO")),
        ("FREQ=YEARLY;BYMONTH=13", .invalidValue(part: "BYMONTH", value: "13")),
        ("FREQ=YEARLY;BYMONTH=-1", .invalidValue(part: "BYMONTH", value: "-1")),
        ("FREQ=MONTHLY;BYMONTHDAY=0", .invalidValue(part: "BYMONTHDAY", value: "0")),
        ("FREQ=MONTHLY;BYMONTHDAY=32", .invalidValue(part: "BYMONTHDAY", value: "32")),
        ("FREQ=DAILY;COUNT=0", .invalidValue(part: "COUNT", value: "0")),
        ("FREQ=DAILY;UNTIL=2026", .invalidValue(part: "UNTIL", value: "2026")),
        ("FREQ=DAILY;UNTIL=20260230", .invalidValue(part: "UNTIL", value: "20260230")),
        ("FREQ=WEEKLY;BYDAY=2MO", .invalidValue(part: "BYDAY", value: "2MO")),
        ("FREQ=WEEKLY;BYMONTHDAY=1", .invalidValue(part: "BYMONTHDAY", value: "1")),
        ("FREQ=DAILY;BYDAY", .invalidValue(part: "BYDAY", value: "")),
    ])
    func refusesWhatItCantRepeat(input: String, error: RecurrenceError) {
        #expect(throws: error) { try Recurrence(rrule: input) }
    }
}
