import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// Which of Agenda's stops a calendar's events are on, in what order, and which meeting an event
/// is matched to.
struct CalendarEventsTests {
    /// A Monday.
    static let today = LocalDate(2026, 10, 26)
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    /// Monday at 11:00.
    static let now = today.date(in: calendar, hour: 11)

    static func event(
        _ title: String, day: Int, hour: Int? = nil, hours: Int = 1, days: Int = 1, reach: CalendarReach = .always
    ) -> CalendarEvent {
        let first = today.adding(days: day)
        let start = first.date(in: calendar, hour: hour ?? 0)
        let end = hour == nil ? first.adding(days: days).date(in: calendar) : start.addingTimeInterval(Double(hours) * 3600)
        return CalendarEvent(
            id: title, title: title, start: start, end: end, isAllDay: hour == nil, calendarID: "home", reach: reach, in: calendar)
    }

    /// The widest layout from Monday 26 October: Today, This Week, Tuesday to Sunday, Next Week (2
    /// to 8 November), the whole of November, then a month at a time.
    static let stops = Timeline.layouts(today: today, weekStart: 2).last ?? []

    static func stop(_ kind: TimelineStop.Kind, first: Int = 0) -> TimelineStop {
        stops.first { $0.kind == kind && $0.first == today.adding(days: first) }!
    }

    func titles(on stop: TimelineStop, _ events: [CalendarEvent]) -> [String] {
        AgendaEvents.events(events, on: stop, today: Self.today, now: Self.now).map(\.title)
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let event: CalendarEvent
        /// The stops it's on, of Today, Tuesday to Sunday (days 1 to 6), Next Week, November and
        /// December.
        let on: [String]
        var testDescription: String { name }
    }

    static let named: [(String, TimelineStop)] =
        [("today", stop(.today))] + (1...6).map { ("day\($0)", stop(.day, first: $0)) }
        + [("nextWeek", stop(.nextWeek, first: 7)), ("november", stop(.month, first: 6)), ("december", stop(.month, first: 36))]

    static let cases: [Case] = [
        Case(name: "an appointment later today", event: event("Dentist", day: 0, hour: 15), on: ["today"]),
        Case(name: "a meeting that's over", event: event("Stand-up", day: 0, hour: 9), on: []),
        Case(name: "an all-day event today, at any hour", event: event("Bin day", day: 0), on: ["today"]),
        Case(name: "a work meeting on Wednesday", event: event("Planning", day: 2, hour: 10, reach: .thisWeek), on: ["day2"]),
        Case(name: "a work meeting next week isn't shown", event: event("Planning", day: 8, hour: 10, reach: .thisWeek), on: []),
        Case(name: "a doctor's appointment next week", event: event("Doctor", day: 8, hour: 9), on: ["nextWeek", "november"]),
        Case(name: "a birthday in December", event: event("Mum's birthday", day: 40), on: ["december"]),
        Case(name: "leave from yesterday to Wednesday", event: event("Leave", day: -1, days: 4), on: ["today", "day1", "day2"]),
        Case(name: "a trip across the month's end", event: event("Trip", day: 34, days: 4), on: ["november", "december"]),
        Case(name: "a calendar that's off", event: event("Hidden", day: 1, hour: 9, reach: .off), on: []),
        Case(name: "a late meeting that ends at midnight", event: event("Late", day: 3, hour: 22, hours: 2), on: ["day3"]),
    ]

    @Test(arguments: cases)
    func eachEventIsOnTheStopsItReaches(_ example: Case) {
        let on = Self.named.filter { !titles(on: $0.1, [example.event]).isEmpty }.map(\.0)
        #expect(on == example.on)
    }

    @Test func allDayEventsComeFirstThenByStart() {
        let events = [
            Self.event("Lunch", day: 1, hour: 12), Self.event("Call", day: 1, hour: 9), Self.event("Birthday", day: 1),
            Self.event("Bins", day: 2),
        ]
        #expect(titles(on: Self.stop(.day, first: 1), events) == ["Birthday", "Call", "Lunch"])
        let thisWeek = Timeline.layouts(today: Self.today, weekStart: 2)[0].first { $0.kind == .thisWeek }!
        #expect(titles(on: thisWeek, events) == ["Birthday", "Call", "Lunch", "Bins"])
    }

    @Test func laterHasWhatsAfterTheLastStop() {
        let narrow = Timeline.layouts(today: Self.today, weekStart: 2)[0]
        let later = narrow.last!
        #expect(titles(on: later, [Self.event("Wedding", day: 200), Self.event("Doctor", day: 8, hour: 9)]) == ["Wedding"])
        #expect(titles(on: later, [Self.event("Conference", day: 200, reach: .thisWeek)]).isEmpty)
    }

    @Test func onlyCalendarsShownAlwaysMarkTheTimeline() {
        let events = [Self.event("Doctor", day: 8, hour: 9), Self.event("Planning", day: 2, hour: 10, reach: .thisWeek)]
        let filled = AgendaEvents.filled(Self.stops, events, today: Self.today, now: Self.now)
        #expect(filled == [Self.stop(.nextWeek, first: 7), Self.stop(.month, first: 6)])
    }

    @Test func theReviewSeesFourWeeksOfCalendarsShownAlways() {
        let events = [
            Self.event("Doctor", day: 8, hour: 9), Self.event("Planning", day: 2, hour: 10, reach: .thisWeek),
            Self.event("Birthday", day: 40),
        ]
        let ahead = AgendaEvents.ahead(Self.stops, events, today: Self.today, now: Self.now)
        #expect(ahead.map(\.stop) == [Self.stop(.nextWeek, first: 7)] && ahead.flatMap(\.events).map(\.title) == ["Doctor"])
    }

    // MARK: Meetings

    static func meeting(_ title: String, series: String, day: Int = 0, recurring: Bool = true) -> CalendarEvent {
        let start = today.adding(days: day).date(in: calendar, hour: 15)
        return CalendarEvent(
            id: "\(series)-\(day)", title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: false, calendarID: "work",
            reach: .always, seriesID: series, isRecurring: recurring, in: calendar)
    }

    @MainActor final class Notes {
        let context = ModelContext(try! TasksSchema.container(at: nil))

        func note(_ title: String, _ bucket: Bucket = .reference, series: String? = nil, raising: [String] = []) -> Item {
            let note = Item(title: title, bucket: bucket)
            note.kind = .note
            note.calendarEventID = series
            context.insert(note)
            for (index, title) in raising.enumerated() {
                let raised = Item(title: title, bucket: .action)
                raised.sortOrder = Double(index)
                context.insert(raised)
                raised.parent = note
            }
            return note
        }

        var items: [Item] { (try? context.fetch(FetchDescriptor<Item>())) ?? [] }
    }

    @MainActor @Test func anEventIsMatchedToTheMeetingNoteLinkedToItsSeries() throws {
        let notes = Notes()
        let noor = notes.note("1:1 with Noor", series: "noor", raising: ["Training budget", "On-call rota"])
        _ = notes.note("Product monthly", series: "product")
        _ = notes.note("Team lunch", .action, series: "lunch", raising: ["Book a table"])
        _ = notes.note("1:1 with Sam", raising: ["Holiday cover"])
        func match(_ title: String, _ series: String) -> Item? { AgendaEvents.meeting(for: Self.meeting(title, series: series), in: notes.items) }

        #expect(match("1:1 with Noor", "noor") === noor)
        #expect(match("Noor / Alex", "noor") === noor, "the event renamed")
        noor.title = "Noor"
        #expect(match("1:1 with Noor", "noor") === noor, "the note renamed")
        #expect(AgendaEvents.openSubtasks(of: noor).map(\.title) == ["Training budget", "On-call rota"])
        #expect(match("Product monthly", "product") == nil, "nothing to raise")
        #expect(AgendaEvents.linkedNote(for: Self.meeting("Product monthly", series: "product"), in: notes.items)?.title == "Product monthly")
        #expect(match("Team lunch", "lunch") == nil, "not in Reference")
        #expect(match("1:1 with Sam", "sam") == nil, "named alike but not linked")
        #expect(match("", "") == nil, "a calendar with no series")
        for raised in noor.children ?? [] { raised.markDone() }
        #expect(match("1:1 with Noor", "noor") == nil, "everything raised")
    }

    @MainActor @Test func linkingANoteTakesTheLinkOffAnyOtherAndCanBeUndone() throws {
        let notes = Notes()
        let old = notes.note("Noor", series: "noor")
        let new = notes.note("1:1 with Noor")
        let undo = try #require(AgendaEvents.link(new, to: "noor", in: notes.context))
        #expect(new.calendarEventID == "noor" && old.calendarEventID == nil)
        #expect(AgendaEvents.link(new, to: "noor", in: notes.context) == nil, "already linked")
        #expect(Clarifier.undo(undo, in: notes.context))
        #expect(new.calendarEventID == nil && old.calendarEventID == "noor")

        _ = try #require(AgendaEvents.link(nil, to: "noor", in: notes.context))
        #expect(notes.items.allSatisfy { $0.calendarEventID == nil })
    }

    @MainActor @Test func aNewMeetingNoteIsNamedLikeTheEventAndLinkedToIt() throws {
        let notes = Notes()
        let old = notes.note("Noor", series: "noor")
        let made = AgendaEvents.newMeetingNote(for: Self.meeting("1:1 with Noor", series: "noor"), in: notes.context)
        #expect(made.note.title == "1:1 with Noor" && made.note.kind == .note && made.note.bucket == .reference)
        #expect(made.note.calendarEventID == "noor" && old.calendarEventID == nil)
        #expect(Clarifier.undo(made.undo, in: notes.context))
        #expect(notes.items.map(\.title) == ["Noor"] && old.calendarEventID == "noor")
    }

    @Test(arguments: [
        ("7q2kd9vbm3xa0rf5tl8ehc4wun_R20260302T150000@google.com/RID=794502000", "7q2kd9vbm3xa0rf5tl8ehc4wun@google.com"),
        ("7q2kd9vbm3xa0rf5tl8ehc4wun@google.com/RID=794588400", "7q2kd9vbm3xa0rf5tl8ehc4wun@google.com"),
        ("4nfj1pz6ow8cq0yd3mrb9ts5ke_R20240109T170000@google.com", "4nfj1pz6ow8cq0yd3mrb9ts5ke@google.com"),
        ("4nfj1pz6ow8cq0yd3mrb9ts5ke_R20240109T170000Z@google.com", "4nfj1pz6ow8cq0yd3mrb9ts5ke@google.com"),
        ("hb3xw7ge2ka9vm0qr6dn1tl4so@google.com", "hb3xw7ge2ka9vm0qr6dn1tl4so@google.com"),
        ("C4E1F2A0-7B3D-4E55-9A61-2F0C8D9E1B23", "C4E1F2A0-7B3D-4E55-9A61-2F0C8D9E1B23"),
        ("budget_Review@example.com", "budget_Review@example.com"),
        ("", ""),
    ])
    func aChangedOrSplitOccurrenceIsInItsSeries(external: String, series: String) {
        #expect(AgendaEvents.seriesID(external) == series)
    }

    @MainActor @Test func aNoteLinkedToAChangedOccurrenceIsTheSeriesNote() throws {
        let notes = Notes()
        let note = notes.note("Morning Check-in", series: "7q2kd_R20260302T150000@google.com/RID=794502000")
        let event = Self.meeting("Morning Check-in", series: "7q2kd@google.com")
        #expect(AgendaEvents.linkedNote(for: event, in: notes.items) === note)
        _ = try #require(AgendaEvents.link(nil, to: event.seriesID, in: notes.context))
        #expect(note.calendarEventID == nil)
    }

    @MainActor @Test func aSeriesStartedAgainFindsItsNoteByTitle() {
        let notes = Notes()
        let note = notes.note("Jordan / Alex", series: "4nfj1@google.com")
        _ = notes.note("Jordan / Alex")
        #expect(AgendaEvents.linkedNote(for: Self.meeting(" jordan / alex", series: "hb3xw@google.com"), in: notes.items) === note)
        #expect(AgendaEvents.linkedNote(for: Self.meeting("Jordan and Alex", series: "hb3xw@google.com"), in: notes.items) == nil)
    }

    @MainActor @Test func aNoteLinkedToTheSeriesComesBeforeOneWithItsTitle() {
        let notes = Notes()
        _ = notes.note("Stand-up", series: "old@google.com")
        let linked = notes.note("Team stand-up", series: "new@google.com")
        #expect(AgendaEvents.linkedNote(for: Self.meeting("Stand-up", series: "new@google.com"), in: notes.items) === linked)
    }

    @Test func aSeriesNoteIDIsTheSameForTheSameSeries() {
        #expect(AgendaEvents.noteID(for: "noor") == AgendaEvents.noteID(for: "noor"))
        #expect(AgendaEvents.noteID(for: "noor") != AgendaEvents.noteID(for: "standup"))
    }

    @MainActor @Test func aNewMeetingNoteTakesItsSeriesNoteID() {
        let notes = Notes()
        let made = AgendaEvents.newMeetingNote(for: Self.meeting("1:1 with Noor", series: "noor"), in: notes.context)
        #expect(made.note.id == AgendaEvents.noteID(for: "noor"))
    }

    @MainActor @Test func aNewMeetingNoteGetsANewIDWhenAnotherItemHasItsSeriesNoteID() throws {
        let notes = Notes()
        let first = AgendaEvents.newMeetingNote(for: Self.meeting("1:1 with Noor", series: "noor"), in: notes.context)
        _ = try #require(AgendaEvents.link(nil, to: "noor", in: notes.context))
        Clarifier.file(first.note, ClarifyOutcome(.trash), today: Self.today)
        let second = AgendaEvents.newMeetingNote(for: Self.meeting("1:1 with Noor", series: "noor"), in: notes.context)
        #expect(second.note.id != first.note.id && second.note.calendarEventID == "noor")
        #expect(first.note.bucket == .trash && first.note.calendarEventID == nil)
    }

    @Test func eachRepeatingSeriesIsOfferedOnceByTitle() {
        let events = [
            Self.meeting("Stand-up", series: "standup", day: 1), Self.meeting("Stand-up", series: "standup", day: 0),
            Self.meeting("1:1 with Noor", series: "noor", day: 3), Self.meeting("Dentist", series: "dentist", recurring: false),
            Self.meeting("No series", series: ""),
        ]
        let series = AgendaEvents.series(events)
        #expect(series.map(\.title) == ["1:1 with Noor", "Stand-up"])
        #expect(series.last?.id == "standup-0", "its first occurrence")
    }

    @Test(
        arguments: [
            (0, false, 0, 0), (5, false, 5, 0), (7, false, 7, 0), (8, false, 5, 3), (20, false, 5, 15), (20, true, 20, 0),
        ] as [(Int, Bool, Int, Int)])
    func longListsOfEventsFoldAfterTheFirstFive(count: Int, isOpenedOut: Bool, shown: Int, more: Int) {
        let folded = AgendaEvents.folded(Array(0..<count), isOpenedOut: isOpenedOut)
        #expect(folded.shown == Array(0..<shown))
        #expect(folded.more == more)
    }

    @Test func theLineForMoreEventsIsTheSameRowEachTime() {
        let stops = Timeline.layouts(today: LocalDate(2026, 10, 21), weekStart: 2).last ?? []
        #expect(AgendaEvents.moreEventsID(for: stops[0]) == AgendaEvents.moreEventsID(for: stops[0]))
        #expect(Set(stops.map(AgendaEvents.moreEventsID)).count == stops.count)
    }
}
