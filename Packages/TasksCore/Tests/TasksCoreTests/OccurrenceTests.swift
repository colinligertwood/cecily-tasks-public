import Foundation
import Testing

@testable import TasksCore

/// One rule, the day its series starts, and the days it should fall on. The expected days were
/// worked out separately, by checking every day in turn rather than stepping period by period.
struct RuleCase: CustomTestStringConvertible, Sendable {
    let name: String
    let rule: String
    let start: LocalDate
    let expected: [LocalDate]
    let limit: Int

    init(_ name: String, _ rule: String, from start: String, _ expected: [String], limit: Int? = nil) {
        self.name = name
        self.rule = rule
        self.start = LocalDate(start)!
        self.expected = expected.map { LocalDate($0)! }
        self.limit = limit ?? expected.count
    }

    var testDescription: String { name }
}

struct OccurrenceTests {
    static let cases: [RuleCase] = [
        RuleCase(
            "every weekday", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", from: "2026-10-20",
            ["2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29"]),
        RuleCase(
            "every 2 weeks on Mon and Thu", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH", from: "2026-10-20",
            ["2026-10-22", "2026-11-02", "2026-11-05", "2026-11-16", "2026-11-19", "2026-11-30"]),
        RuleCase(
            "last Friday of each month", "FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1", from: "2026-10-20",
            ["2026-10-30", "2026-11-27", "2026-12-25", "2027-01-29", "2027-02-26", "2027-03-26"]),
        RuleCase(
            "last Friday of each month, as -1FR", "FREQ=MONTHLY;BYDAY=-1FR", from: "2026-10-20",
            ["2026-10-30", "2026-11-27", "2026-12-25", "2027-01-29", "2027-02-26", "2027-03-26"]),
        RuleCase(
            "1st and 15th of each month", "FREQ=MONTHLY;BYMONTHDAY=1,15", from: "2026-10-20",
            ["2026-11-01", "2026-11-15", "2026-12-01", "2026-12-15", "2027-01-01", "2027-01-15"]),
        RuleCase(
            "last weekday of the month", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", from: "2026-10-20",
            ["2026-10-30", "2026-11-30", "2026-12-31", "2027-01-29", "2027-02-26", "2027-03-31", "2027-04-30", "2027-05-31"]),
        RuleCase(
            "every 3 months on the 2nd Tuesday", "FREQ=MONTHLY;INTERVAL=3;BYDAY=2TU", from: "2026-10-20",
            ["2027-01-12", "2027-04-13", "2027-07-13", "2027-10-12", "2028-01-11"]),
        RuleCase(
            "every year on 15 March", "FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15", from: "2026-10-20",
            ["2027-03-15", "2028-03-15", "2029-03-15", "2030-03-15"]),
        RuleCase(
            "every year on 15 March, from the start day", "FREQ=YEARLY", from: "2027-03-15", ["2027-03-15", "2028-03-15", "2029-03-15", "2030-03-15"]),
        RuleCase(
            "every 6 weeks until 31 December", "FREQ=WEEKLY;INTERVAL=6;UNTIL=20261231", from: "2026-10-20", ["2026-10-20", "2026-12-01"], limit: 10),
        RuleCase(
            "every day, 10 times", "FREQ=DAILY;COUNT=10", from: "2026-10-20",
            [
                "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27", "2026-10-28",
                "2026-10-29",
            ], limit: 20),
        RuleCase("every day", "FREQ=DAILY", from: "2026-10-29", ["2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"]),
        RuleCase(
            "every 3 days across a month end", "FREQ=DAILY;INTERVAL=3", from: "2026-01-28",
            ["2026-01-28", "2026-01-31", "2026-02-03", "2026-02-06", "2026-02-09"]),
        RuleCase(
            "every 2 days across 29 February", "FREQ=DAILY;INTERVAL=2", from: "2028-02-26", ["2028-02-26", "2028-02-28", "2028-03-01", "2028-03-03"]),
        RuleCase("every day across the year end", "FREQ=DAILY", from: "2026-12-30", ["2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02"]),
        RuleCase(
            "every 10 days", "FREQ=DAILY;INTERVAL=10", from: "2026-10-20", ["2026-10-20", "2026-10-30", "2026-11-09", "2026-11-19", "2026-11-29"]),
        RuleCase("every day in March only", "FREQ=DAILY;BYMONTH=3", from: "2026-10-20", ["2027-03-01", "2027-03-02", "2027-03-03"]),
        RuleCase(
            "every day that is a Saturday", "FREQ=DAILY;BYDAY=SA", from: "2026-10-20", ["2026-10-24", "2026-10-31", "2026-11-07", "2026-11-14"]),
        RuleCase(
            "every day that is the 31st", "FREQ=DAILY;BYMONTHDAY=31", from: "2026-10-20",
            ["2026-10-31", "2026-12-31", "2027-01-31", "2027-03-31", "2027-05-31"]),
        RuleCase(
            "every day that is the last of the month", "FREQ=DAILY;BYMONTHDAY=-1", from: "2027-01-01",
            ["2027-01-31", "2027-02-28", "2027-03-31", "2027-04-30", "2027-05-31"]),
        RuleCase("every 7 days", "FREQ=DAILY;INTERVAL=7", from: "2026-10-20", ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10"]),
        RuleCase("every week on the start's weekday", "FREQ=WEEKLY", from: "2026-10-20", ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10"]),
        RuleCase("every week on Monday", "FREQ=WEEKLY;BYDAY=MO", from: "2026-10-20", ["2026-10-26", "2026-11-02", "2026-11-09", "2026-11-16"]),
        RuleCase("every week on Sunday", "FREQ=WEEKLY;BYDAY=SU", from: "2026-10-20", ["2026-10-25", "2026-11-01", "2026-11-08", "2026-11-15"]),
        RuleCase(
            "every week on Mon, Wed, Fri", "FREQ=WEEKLY;BYDAY=MO,WE,FR", from: "2026-10-20",
            ["2026-10-21", "2026-10-23", "2026-10-26", "2026-10-28", "2026-10-30", "2026-11-02", "2026-11-04"]),
        RuleCase(
            "every weekend day", "FREQ=WEEKLY;BYDAY=SA,SU", from: "2026-10-20",
            ["2026-10-24", "2026-10-25", "2026-10-31", "2026-11-01", "2026-11-07", "2026-11-08"]),
        RuleCase(
            "every 2 weeks", "FREQ=WEEKLY;INTERVAL=2", from: "2026-10-20", ["2026-10-20", "2026-11-03", "2026-11-17", "2026-12-01", "2026-12-15"]),
        RuleCase(
            "every 2 weeks on Monday, start on a Tuesday", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", from: "2026-10-20",
            ["2026-11-02", "2026-11-16", "2026-11-30", "2026-12-14"]),
        RuleCase(
            "every 3 weeks on Friday", "FREQ=WEEKLY;INTERVAL=3;BYDAY=FR", from: "2026-12-20",
            ["2027-01-08", "2027-01-29", "2027-02-19", "2027-03-12", "2027-04-02"]),
        RuleCase(
            "every 4 weeks", "FREQ=WEEKLY;INTERVAL=4", from: "2026-12-15", ["2026-12-15", "2027-01-12", "2027-02-09", "2027-03-09", "2027-04-06"]),
        RuleCase("every week across 29 February", "FREQ=WEEKLY", from: "2028-02-22", ["2028-02-22", "2028-02-29", "2028-03-07"]),
        RuleCase(
            "every week on Tuesday in summer months", "FREQ=WEEKLY;BYDAY=TU;BYMONTH=6,7,8", from: "2026-10-20",
            ["2027-06-01", "2027-06-08", "2027-06-15", "2027-06-22"]),
        RuleCase("every week on the start day, a Sunday", "FREQ=WEEKLY", from: "2026-10-25", ["2026-10-25", "2026-11-01", "2026-11-08"]),
        RuleCase(
            "every 2 weeks on Sunday, weeks starting Monday", "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU", from: "2026-10-20",
            ["2026-10-25", "2026-11-08", "2026-11-22", "2026-12-06"]),
        RuleCase(
            "every 2 weeks on Sunday, weeks starting Sunday", "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=SU", from: "2026-10-20",
            ["2026-11-01", "2026-11-15", "2026-11-29", "2026-12-13"]),
        RuleCase(
            "every 2 weeks on Tue and Sun, weeks starting Monday", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU", from: "2026-08-05",
            ["2026-08-09", "2026-08-18", "2026-08-23", "2026-09-01", "2026-09-06", "2026-09-15"]),
        RuleCase(
            "every 2 weeks on Tue and Sun, weeks starting Sunday", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=SU", from: "2026-08-05",
            ["2026-08-16", "2026-08-18", "2026-08-30", "2026-09-01", "2026-09-13", "2026-09-15"]),
        RuleCase("every 52 weeks", "FREQ=WEEKLY;INTERVAL=52", from: "2026-10-20", ["2026-10-20", "2027-10-19", "2028-10-17"]),
        RuleCase("every month on the start day", "FREQ=MONTHLY", from: "2026-10-20", ["2026-10-20", "2026-11-20", "2026-12-20", "2027-01-20"]),
        RuleCase(
            "every month on the 31st skips short months", "FREQ=MONTHLY", from: "2026-01-31",
            ["2026-01-31", "2026-03-31", "2026-05-31", "2026-07-31", "2026-08-31", "2026-10-31", "2026-12-31"]),
        RuleCase(
            "every month on the 30th skips February", "FREQ=MONTHLY", from: "2027-01-30", ["2027-01-30", "2027-03-30", "2027-04-30", "2027-05-30"]),
        RuleCase(
            "every month on the 29th, February in a leap year", "FREQ=MONTHLY", from: "2027-12-29",
            ["2027-12-29", "2028-01-29", "2028-02-29", "2028-03-29"]),
        RuleCase(
            "every month on the 29th, February in a common year", "FREQ=MONTHLY", from: "2026-12-29",
            ["2026-12-29", "2027-01-29", "2027-03-29", "2027-04-29"]),
        RuleCase(
            "every month on the last day", "FREQ=MONTHLY;BYMONTHDAY=-1", from: "2026-10-20",
            [
                "2026-10-31", "2026-11-30", "2026-12-31", "2027-01-31", "2027-02-28", "2027-03-31", "2027-04-30", "2027-05-31", "2027-06-30",
                "2027-07-31", "2027-08-31", "2027-09-30", "2027-10-31",
            ]),
        RuleCase(
            "every month on the last day, leap February", "FREQ=MONTHLY;BYMONTHDAY=-1", from: "2028-01-15",
            ["2028-01-31", "2028-02-29", "2028-03-31"]),
        RuleCase(
            "every month on the second-last day", "FREQ=MONTHLY;BYMONTHDAY=-2", from: "2027-01-01",
            ["2027-01-30", "2027-02-27", "2027-03-30", "2027-04-29"]),
        RuleCase(
            "every month on the 31st by rule", "FREQ=MONTHLY;BYMONTHDAY=31", from: "2026-10-20",
            ["2026-10-31", "2026-12-31", "2027-01-31", "2027-03-31", "2027-05-31"]),
        RuleCase(
            "every month on the 15th and last day", "FREQ=MONTHLY;BYMONTHDAY=15,-1", from: "2027-01-20",
            ["2027-01-31", "2027-02-15", "2027-02-28", "2027-03-15", "2027-03-31", "2027-04-15"]),
        RuleCase(
            "every 2 months on the 31st", "FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=31", from: "2026-01-01",
            ["2026-01-31", "2026-03-31", "2026-05-31", "2026-07-31", "2027-01-31", "2027-03-31"]),
        RuleCase(
            "every 2 months on the 30th", "FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=30", from: "2026-12-01",
            ["2026-12-30", "2027-04-30", "2027-06-30", "2027-08-30"]),
        RuleCase(
            "every 3 months on the 1st", "FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1", from: "2026-10-20",
            ["2027-01-01", "2027-04-01", "2027-07-01", "2027-10-01"]),
        RuleCase(
            "every 6 months on the last day", "FREQ=MONTHLY;INTERVAL=6;BYMONTHDAY=-1", from: "2027-02-01",
            ["2027-02-28", "2027-08-31", "2028-02-29", "2028-08-31"]),
        RuleCase("every 12 months", "FREQ=MONTHLY;INTERVAL=12", from: "2028-02-29", ["2028-02-29", "2032-02-29", "2036-02-29"]),
        RuleCase(
            "every month on the 1st, 10th and 20th", "FREQ=MONTHLY;BYMONTHDAY=1,10,20", from: "2026-10-20",
            ["2026-10-20", "2026-11-01", "2026-11-10", "2026-11-20", "2026-12-01"]),
        RuleCase("every month on the 28th", "FREQ=MONTHLY;BYMONTHDAY=28", from: "2027-01-29", ["2027-02-28", "2027-03-28", "2027-04-28"]),
        RuleCase(
            "every month on the -31st, months with 31 days", "FREQ=MONTHLY;BYMONTHDAY=-31", from: "2026-10-20",
            ["2026-12-01", "2027-01-01", "2027-03-01", "2027-05-01"]),
        RuleCase(
            "first Monday of each month", "FREQ=MONTHLY;BYDAY=1MO", from: "2026-10-20",
            ["2026-11-02", "2026-12-07", "2027-01-04", "2027-02-01", "2027-03-01"]),
        RuleCase(
            "second Tuesday of each month", "FREQ=MONTHLY;BYDAY=2TU", from: "2026-10-20", ["2026-11-10", "2026-12-08", "2027-01-12", "2027-02-09"]),
        RuleCase(
            "fifth Friday where there is one", "FREQ=MONTHLY;BYDAY=5FR", from: "2026-10-20", ["2026-10-30", "2027-01-29", "2027-04-30", "2027-07-30"]),
        RuleCase(
            "fourth Thursday of each month", "FREQ=MONTHLY;BYDAY=4TH", from: "2026-10-20", ["2026-10-22", "2026-11-26", "2026-12-24", "2027-01-28"]),
        RuleCase(
            "second-last Wednesday of each month", "FREQ=MONTHLY;BYDAY=-2WE", from: "2026-10-20",
            ["2026-10-21", "2026-11-18", "2026-12-23", "2027-01-20"]),
        RuleCase(
            "last Sunday of each month", "FREQ=MONTHLY;BYDAY=-1SU", from: "2026-10-20", ["2026-10-25", "2026-11-29", "2026-12-27", "2027-01-31"]),
        RuleCase(
            "first and third Wednesday", "FREQ=MONTHLY;BYDAY=1WE,3WE", from: "2026-10-20",
            ["2026-10-21", "2026-11-04", "2026-11-18", "2026-12-02", "2026-12-16", "2027-01-06"]),
        RuleCase(
            "every Tuesday in the month", "FREQ=MONTHLY;BYDAY=TU", from: "2026-10-20",
            ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10", "2026-11-17", "2026-11-24"]),
        RuleCase(
            "first weekend day of each month", "FREQ=MONTHLY;BYDAY=SA,SU;BYSETPOS=1", from: "2026-10-20",
            ["2026-11-01", "2026-12-05", "2027-01-02", "2027-02-06", "2027-03-06"]),
        RuleCase(
            "Friday the 13th", "FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", from: "2026-01-01", ["2026-02-13", "2026-03-13", "2026-11-13", "2027-08-13"]),
        RuleCase(
            "first Monday on or after the 8th", "FREQ=MONTHLY;BYDAY=MO;BYMONTHDAY=8,9,10,11,12,13,14", from: "2026-10-20",
            ["2026-11-09", "2026-12-14", "2027-01-11", "2027-02-08"]),
        RuleCase(
            "every 2 months on the last Friday", "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR", from: "2026-10-20",
            ["2026-10-30", "2026-12-25", "2027-02-26", "2027-04-30"]),
        RuleCase("first Monday across February 2027", "FREQ=MONTHLY;BYDAY=1MO", from: "2027-01-10", ["2027-02-01", "2027-03-01", "2027-04-05"]),
        RuleCase(
            "last Monday in a leap February", "FREQ=MONTHLY;BYDAY=-1MO;BYMONTH=2", from: "2027-01-01", ["2027-02-22", "2028-02-28", "2029-02-26"]),
        RuleCase(
            "first weekday of the month", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1", from: "2026-10-20",
            ["2026-11-02", "2026-12-01", "2027-01-01", "2027-02-01", "2027-03-01", "2027-04-01"]),
        RuleCase(
            "second weekday of the month", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=2", from: "2026-10-20",
            ["2026-11-03", "2026-12-02", "2027-01-04", "2027-02-02"]),
        RuleCase(
            "last weekday of the month, month ending on a weekend", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", from: "2027-01-01",
            ["2027-01-29", "2027-02-26", "2027-03-31", "2027-04-30", "2027-05-31", "2027-06-30"]),
        RuleCase(
            "first and last weekday", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1,-1", from: "2026-10-20",
            ["2026-10-30", "2026-11-02", "2026-11-30", "2026-12-01", "2026-12-31", "2027-01-01"]),
        RuleCase(
            "third-last day of the month by set position", "FREQ=MONTHLY;BYMONTHDAY=-1,-2,-3;BYSETPOS=1", from: "2027-01-01",
            ["2027-01-29", "2027-02-26", "2027-03-29", "2027-04-28"]),
        RuleCase(
            "last working day of the quarter", "FREQ=MONTHLY;INTERVAL=3;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", from: "2026-12-01",
            ["2026-12-31", "2027-03-31", "2027-06-30", "2027-09-30"]),
        RuleCase(
            "last weekday of the year", "FREQ=YEARLY;BYMONTH=12;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", from: "2026-10-20",
            ["2026-12-31", "2027-12-31", "2028-12-29", "2029-12-31"]),
        RuleCase(
            "first weekday of the year", "FREQ=YEARLY;BYMONTH=1;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1", from: "2026-10-20",
            ["2027-01-01", "2028-01-03", "2029-01-01", "2030-01-01"]),
        RuleCase(
            "last day of each week, weekly set position", "FREQ=WEEKLY;BYDAY=MO,WE,FR;BYSETPOS=-1", from: "2026-10-20",
            ["2026-10-23", "2026-10-30", "2026-11-06"]),
        RuleCase("every year on the start day", "FREQ=YEARLY", from: "2026-10-20", ["2026-10-20", "2027-10-20", "2028-10-20"]),
        RuleCase("every year on 29 February: leap years only", "FREQ=YEARLY", from: "2028-02-29", ["2028-02-29", "2032-02-29", "2036-02-29"]),
        RuleCase(
            "every year on 29 February by rule", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29", from: "2026-10-20",
            ["2028-02-29", "2032-02-29", "2036-02-29"]),
        RuleCase(
            "every year on the last day of February", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1", from: "2026-10-20",
            ["2027-02-28", "2028-02-29", "2029-02-28", "2030-02-28", "2031-02-28"]),
        RuleCase("every 4 years on 29 February", "FREQ=YEARLY;INTERVAL=4", from: "2024-02-29", ["2024-02-29", "2028-02-29", "2032-02-29"]),
        RuleCase("every 2 years", "FREQ=YEARLY;INTERVAL=2", from: "2026-10-20", ["2026-10-20", "2028-10-20", "2030-10-20"]),
        RuleCase(
            "every year in January and July on the start day", "FREQ=YEARLY;BYMONTH=1,7", from: "2026-10-20",
            ["2027-01-20", "2027-07-20", "2028-01-20", "2028-07-20"]),
        RuleCase(
            "every year on 31 January and 31 July", "FREQ=YEARLY;BYMONTH=1,7;BYMONTHDAY=31", from: "2026-10-20",
            ["2027-01-31", "2027-07-31", "2028-01-31", "2028-07-31"]),
        RuleCase(
            "fourth Thursday of November", "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH", from: "2026-10-20",
            ["2026-11-26", "2027-11-25", "2028-11-23", "2029-11-22"]),
        RuleCase(
            "last Monday of May", "FREQ=YEARLY;BYMONTH=5;BYDAY=-1MO", from: "2026-10-20", ["2027-05-31", "2028-05-29", "2029-05-28", "2030-05-27"]),
        RuleCase(
            "second Sunday of March", "FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", from: "2026-10-20", ["2027-03-14", "2028-03-12", "2029-03-11", "2030-03-10"]),
        RuleCase("first Sunday of the year", "FREQ=YEARLY;BYDAY=1SU", from: "2026-10-20", ["2027-01-03", "2028-01-02", "2029-01-07", "2030-01-06"]),
        RuleCase("last Friday of the year", "FREQ=YEARLY;BYDAY=-1FR", from: "2026-10-20", ["2026-12-25", "2027-12-31", "2028-12-29", "2029-12-28"]),
        RuleCase("20th Monday of the year", "FREQ=YEARLY;BYDAY=20MO", from: "2026-10-20", ["2027-05-17", "2028-05-15", "2029-05-14"]),
        RuleCase(
            "every year on the 1st of each month by rule", "FREQ=YEARLY;BYMONTHDAY=1", from: "2026-10-20",
            ["2026-11-01", "2026-12-01", "2027-01-01", "2027-02-01", "2027-03-01"]),
        RuleCase(
            "every year on 31 December across a year end", "FREQ=YEARLY;BYMONTH=12;BYMONTHDAY=31", from: "2026-12-31",
            ["2026-12-31", "2027-12-31", "2028-12-31"]),
        RuleCase("every week, 3 times", "FREQ=WEEKLY;COUNT=3", from: "2026-10-20", ["2026-10-20", "2026-10-27", "2026-11-03"], limit: 10),
        RuleCase(
            "every month on the 31st, 4 times", "FREQ=MONTHLY;BYMONTHDAY=31;COUNT=4", from: "2026-10-20",
            ["2026-10-31", "2026-12-31", "2027-01-31", "2027-03-31"], limit: 10),
        RuleCase(
            "last weekday, 3 times", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3", from: "2026-10-20",
            ["2026-10-30", "2026-11-30", "2026-12-31"], limit: 10),
        RuleCase(
            "every day until the 25th, inclusive", "FREQ=DAILY;UNTIL=20261025", from: "2026-10-20",
            ["2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"], limit: 10),
        RuleCase(
            "every month on the 31st until March", "FREQ=MONTHLY;UNTIL=20270331", from: "2026-10-31",
            ["2026-10-31", "2026-12-31", "2027-01-31", "2027-03-31"], limit: 10),
        RuleCase("every year until a day before the next", "FREQ=YEARLY;UNTIL=20271019", from: "2026-10-20", ["2026-10-20"], limit: 10),
        RuleCase(
            "until with a time, date part used", "FREQ=WEEKLY;UNTIL=20261110T235959Z", from: "2026-10-20",
            ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10"], limit: 10),
        RuleCase("until before the start", "FREQ=DAILY;UNTIL=20261001", from: "2026-10-20", [], limit: 10),
        RuleCase("count of one", "FREQ=YEARLY;COUNT=1", from: "2026-10-20", ["2026-10-20"], limit: 10),
        RuleCase(
            "every 2 weeks on Mon and Thu, 5 times", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;COUNT=5", from: "2026-10-20",
            ["2026-10-22", "2026-11-02", "2026-11-05", "2026-11-16", "2026-11-19"], limit: 10),
        RuleCase(
            "start not matching: first Monday from 3 November", "FREQ=MONTHLY;BYDAY=1MO", from: "2026-11-03",
            ["2026-12-07", "2027-01-04", "2027-02-01"]),
        RuleCase(
            "every 100 years on 29 February", "FREQ=YEARLY;INTERVAL=100;BYMONTH=2;BYMONTHDAY=29", from: "2000-01-01", ["2000-02-29", "2400-02-29"]),
        RuleCase(
            "every 3 months on the 31st", "FREQ=MONTHLY;INTERVAL=3", from: "2026-01-31",
            ["2026-01-31", "2026-07-31", "2026-10-31", "2027-01-31", "2027-07-31"]),
    ]

    @Test(arguments: cases)
    func occurrences(of example: RuleCase) throws {
        let rule = try Recurrence(rrule: example.rule)
        #expect(rule.occurrences(from: example.start, limit: example.limit) == example.expected)
    }

    @Test func theTableHasAtLeastAHundredCases() {
        #expect(Self.cases.count >= 100)
    }

    @Test(arguments: cases)
    func nextOccurrenceStepsThroughTheSeries(of example: RuleCase) throws {
        let rule = try Recurrence(rrule: example.rule)
        var day = example.start.adding(days: -1)
        for expected in example.expected {
            let next = try #require(rule.nextOccurrence(after: day, seriesStart: example.start))
            #expect(next == expected)
            day = next
        }
    }

    @Test func aRuleThatCanNeverMatchEnds() throws {
        let rule = try Recurrence(rrule: "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30")
        #expect(rule.occurrences(from: LocalDate(2026, 1, 1), limit: 3).isEmpty)
    }

    @Test func aRuleWithNoEndKeepsGoingForCenturies() throws {
        let rule = try Recurrence(rrule: "FREQ=MONTHLY;BYDAY=-1FR")
        let days = rule.occurrences(from: LocalDate(2026, 10, 20), limit: 1200)
        #expect(days.count == 1200)
        #expect(days.last == LocalDate(2126, 9, 27))
        #expect(days.allSatisfy { $0.weekday == 6 && $0.adding(days: 7).month != $0.month })
    }
}
