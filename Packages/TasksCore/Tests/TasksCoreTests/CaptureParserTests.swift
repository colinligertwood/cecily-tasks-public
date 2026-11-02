import Foundation
import Testing

@testable import TasksCore

struct CaptureParserTests {
    /// Tuesday.
    static let today = LocalDate(2026, 10, 20)
    static let vocabulary = CaptureVocabulary(projects: ["Kitchen refit", "Tax return"], contexts: ["Calls", "Errands", "Computer"])

    func parse(_ text: String) -> [CaptureDraft] {
        CaptureParser.parse(text, today: Self.today, vocabulary: Self.vocabulary)
    }

    func one(_ text: String) throws -> CaptureDraft {
        let drafts = parse(text)
        try #require(drafts.count == 1)
        return drafts[0]
    }

    @Test func plainTextIsJustATitle() throws {
        let draft = try one("Email Sam for the policy number")
        #expect(draft == CaptureDraft(title: "Email Sam for the policy number"))
    }

    @Test func eachLineIsAnItem() {
        let drafts = parse("Buy milk\n\n  Call the bank  \nBook the van\n")
        #expect(drafts.map(\.title) == ["Buy milk", "Call the bank", "Book the van"])
    }

    @Test(arguments: [
        ("Ask about worktops #kitchen-refit", "Kitchen refit"), ("#Kitchen_Refit measure", "Kitchen refit"), ("#TAX-RETURN find P60", "Tax return"),
    ])
    func aHashNamesAProject(text: String, project: String) throws {
        let draft = try one(text)
        #expect(draft.project == project)
        #expect(!draft.title.contains("#"))
    }

    @Test func anUnknownProjectStaysAsText() throws {
        let draft = try one("Plant bulbs #garden")
        #expect(draft.project == nil && draft.title == "Plant bulbs #garden")
    }

    @Test func atNamesContexts() throws {
        let draft = try one("Ring the garage @calls @errands @calls")
        #expect(draft.contexts == ["Calls", "Errands"] && draft.title == "Ring the garage")
    }

    @Test func anUnknownContextAndAnEmailAddressStayAsText() throws {
        let draft = try one("Reply to sam@example.com @home")
        #expect(draft.contexts.isEmpty && draft.title == "Reply to sam@example.com @home")
    }

    @Test(arguments: [
        ("due:today", LocalDate(2026, 10, 20)), ("due:tomorrow", LocalDate(2026, 10, 21)), ("due:tmr", LocalDate(2026, 10, 21)),
        ("due:tue", LocalDate(2026, 10, 20)), ("due:wed", LocalDate(2026, 10, 21)), ("due:fri", LocalDate(2026, 10, 23)),
        ("due:friday", LocalDate(2026, 10, 23)), ("due:mon", LocalDate(2026, 10, 26)), ("due:sun", LocalDate(2026, 10, 25)),
        ("due:2026-11-06", LocalDate(2026, 11, 6)), ("due:+3d", LocalDate(2026, 10, 23)), ("due:+2w", LocalDate(2026, 11, 3)),
        ("DUE:Fri", LocalDate(2026, 10, 23)),
    ])
    func dueDates(token: String, day: LocalDate) throws {
        let draft = try one("Pay the deposit \(token)")
        #expect(draft.dueDate == day && draft.title == "Pay the deposit")
    }

    @Test(arguments: [("!tomorrow", LocalDate(2026, 10, 21)), ("!thu", LocalDate(2026, 10, 22)), ("!2027-01-04", LocalDate(2027, 1, 4))])
    func scheduledDates(token: String, day: LocalDate) throws {
        let draft = try one("\(token) Dentist")
        #expect(draft.scheduledDate == day && draft.title == "Dentist")
    }

    @Test(arguments: ["due:someday", "!important", "due:", "!", "due:2026-02-30"])
    func unreadableDatesStayAsText(_ token: String) throws {
        let draft = try one("Thing \(token)")
        #expect(draft.dueDate == nil && draft.scheduledDate == nil && draft.title == "Thing \(token)")
    }

    @Test func weekdaysCrossAMonthEnd() {
        // Friday 30 October 2026.
        let friday = LocalDate(2026, 10, 30)
        #expect(CaptureParser.day("fri", today: friday) == friday)
        #expect(CaptureParser.day("mon", today: friday) == LocalDate(2026, 11, 2))
        #expect(CaptureParser.day("tomorrow", today: LocalDate(2026, 12, 31)) == LocalDate(2027, 1, 1))
    }

    @Test(arguments: [
        ("every day", "FREQ=DAILY"), ("every 2 weeks", "FREQ=WEEKLY;INTERVAL=2"), ("every month", "FREQ=MONTHLY"),
        ("every 3 months", "FREQ=MONTHLY;INTERVAL=3"), ("every year", "FREQ=YEARLY"), ("every weekday", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"),
        ("every monday", "FREQ=WEEKLY;BYDAY=MO"), ("Every 2 Fri", "FREQ=WEEKLY;INTERVAL=2;BYDAY=FR"), ("every 10 days", "FREQ=DAILY;INTERVAL=10"),
    ])
    func repeats(phrase: String, rrule: String) throws {
        let draft = try one("Water the plants \(phrase)")
        guard case .schedule(let recurrence) = draft.repeatRule?.mode else {
            Issue.record("no repeat")
            return
        }
        #expect(recurrence.rrule == rrule)
        #expect(draft.repeatText == phrase && draft.title == "Water the plants")
    }

    @Test(arguments: ["every so often", "every", "everyone said so", "every 0 days"])
    func phrasesThatArentRepeatsStayAsText(_ phrase: String) throws {
        let draft = try one("Smile \(phrase)")
        #expect(draft.repeatRule == nil && draft.title == "Smile \(phrase)")
    }

    @Test func everythingTogether() throws {
        let draft = try one("Call the builder @calls #kitchen-refit due:fri !thu every 2 weeks about the tiles")
        #expect(draft.title == "Call the builder about the tiles")
        #expect(draft.contexts == ["Calls"] && draft.project == "Kitchen refit")
        #expect(draft.dueDate == LocalDate(2026, 10, 23) && draft.scheduledDate == LocalDate(2026, 10, 22))
        #expect(draft.repeatText == "every 2 weeks")
    }

    @Test func onlyTheFirstProjectAndDatesCount() throws {
        let draft = try one("Thing #kitchen-refit #tax-return due:mon due:tue")
        #expect(draft.project == "Kitchen refit" && draft.dueDate == LocalDate(2026, 10, 26))
        #expect(draft.title == "Thing #tax-return due:tue")
    }

    @Test func aLineOfOnlyTokensKeepsItsProject() throws {
        let drafts = parse("@calls\n#kitchen-refit")
        #expect(drafts.count == 1 && drafts.first?.project == "Kitchen refit" && drafts.first?.title == "")
    }
}
