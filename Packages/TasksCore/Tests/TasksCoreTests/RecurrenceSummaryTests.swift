import Foundation
import Testing

@testable import TasksCore

/// How a calendar event's repeat rule is put in words.
struct RecurrenceSummaryTests {
    @Test(arguments: [
        ("FREQ=DAILY", "Every day"),
        ("FREQ=DAILY;INTERVAL=3", "Every 3 days"),
        ("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", "Every weekday"),
        ("FREQ=WEEKLY", "Every week"),
        ("FREQ=WEEKLY;BYDAY=TH", "Every Thursday"),
        ("FREQ=WEEKLY;BYDAY=TH,MO", "Every Monday and Thursday"),
        ("FREQ=WEEKLY;BYDAY=MO,WE,FR", "Every Monday, Wednesday and Friday"),
        ("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "Every weekday"),
        ("FREQ=WEEKLY;BYDAY=SU,SA;WKST=SU", "Every Sunday and Saturday"),
        ("FREQ=WEEKLY;INTERVAL=2", "Every 2 weeks"),
        ("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", "Every 2 weeks on Monday"),
        ("FREQ=MONTHLY", "Monthly"),
        ("FREQ=MONTHLY;BYDAY=1TU", "Monthly on the first Tuesday"),
        ("FREQ=MONTHLY;BYDAY=-1FR", "Monthly on the last Friday"),
        ("FREQ=MONTHLY;BYDAY=-2FR", "Monthly on the second to last Friday"),
        ("FREQ=MONTHLY;BYDAY=TH;BYSETPOS=3", "Monthly on the third Thursday"),
        ("FREQ=MONTHLY;BYMONTHDAY=15", "Monthly on the 15th"),
        ("FREQ=MONTHLY;BYMONTHDAY=1", "Monthly on the 1st"),
        ("FREQ=MONTHLY;BYMONTHDAY=22", "Monthly on the 22nd"),
        ("FREQ=MONTHLY;BYMONTHDAY=13", "Monthly on the 13th"),
        ("FREQ=MONTHLY;BYMONTHDAY=-1", "Monthly on the last day"),
        ("FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1", "Every 3 months on the 1st"),
        ("FREQ=YEARLY", "Every year"),
        ("FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=14", "Every year on 14 March"),
        ("FREQ=YEARLY;BYMONTH=5;BYDAY=2SU", "Every year on the second Sunday of May"),
        ("FREQ=YEARLY;INTERVAL=2;BYMONTH=6", "Every 2 years in June"),
        ("FREQ=WEEKLY;BYDAY=TH;COUNT=10", "Every Thursday, 10 times"),
        ("FREQ=DAILY;COUNT=1", "Every day, once"),
        ("FREQ=WEEKLY;BYDAY=TH;UNTIL=20261210", "Every Thursday, until 10 Dec 2026"),
    ])
    func putsTheRuleInWords(rrule: String, summary: String) throws {
        #expect(try Recurrence(rrule: rrule).summary == summary)
    }
}
