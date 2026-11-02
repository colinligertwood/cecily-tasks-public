import Foundation
import SwiftData

/// How far ahead Agenda shows a calendar's events.
public enum CalendarReach: String, CaseIterable, Sendable {
    /// On every stop.
    case always
    /// Only on Today, the six days after it and This Week.
    case thisWeek
    case off

    /// What a calendar starts with.
    public static let initial = CalendarReach.thisWeek
}

/// An event from one of the device's calendars, as Agenda shows it.
public struct CalendarEvent: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarID: String
    public let reach: CalendarReach
    /// The series it belongs to, the same on every device: a repeating event's occurrences share
    /// it. Empty when the calendar doesn't give one.
    public let seriesID: String
    public let isRecurring: Bool
    public let isCancelled: Bool
    public let firstDay: LocalDate
    public let lastDay: LocalDate

    /// An event's days are those it covers in `calendar`; one that ends at midnight ends the day
    /// before.
    public init(
        id: String, title: String, start: Date, end: Date, isAllDay: Bool, calendarID: String, reach: CalendarReach, seriesID: String = "",
        isRecurring: Bool = false, isCancelled: Bool = false, in calendar: Calendar
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.reach = reach
        self.seriesID = seriesID
        self.isRecurring = isRecurring
        self.isCancelled = isCancelled
        firstDay = LocalDate(start, in: calendar)
        lastDay = max(firstDay, LocalDate(end.addingTimeInterval(-1), in: calendar))
    }

    /// Its ID as a UUID, the same each time, so its row can be selected among items' rows.
    public var selectionID: UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in Self.digest(id).enumerated() { bytes[index % 16] ^= byte }
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// Two 64-bit FNV-1a hashes of `text`, the second seeded differently, as 16 bytes.
    private static func digest(_ text: String) -> [UInt8] {
        func fnv(_ seed: UInt64) -> UInt64 {
            text.utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        }
        return [fnv(0xcbf2_9ce4_8422_2325), fnv(0x8422_2325_cbf2_9ce4)].flatMap { value in
            (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
    }
}

public enum AgendaEvents {
    /// How far ahead events are read, in days.
    public static let daysAhead = 400

    /// The events on `stop`, at `now` on `today`: those with a day in it from today on, from
    /// calendars that reach it, leaving out timed events that have ended. All-day events come
    /// first on each day, then the rest by their start, then by title.
    public static func events(_ events: [CalendarEvent], on stop: TimelineStop, today: LocalDate, now: Date) -> [CalendarEvent] {
        events.filter { event in
            guard reaches(event.reach, stop), event.isAllDay || event.end > now else { return false }
            let from = max(event.firstDay, today)
            guard from <= event.lastDay else { return false }
            switch stop.kind {
            case .today: return from <= stop.first
            case .later: return event.lastDay >= stop.first
            default: return from <= (stop.last ?? stop.first) && event.lastDay >= stop.first
            }
        }
        .sorted { a, b in
            let (dayA, dayB) = (max(a.firstDay, today), max(b.firstDay, today))
            if dayA != dayB { return dayA < dayB }
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.start != b.start { return a.start < b.start }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// The stops with an event from a calendar that's shown always.
    public static func filled(_ stops: [TimelineStop], _ events: [CalendarEvent], today: LocalDate, now: Date) -> Set<TimelineStop> {
        let always = events.filter { $0.reach == .always }
        return Set(stops.filter { !Self.events(always, on: $0, today: today, now: now).isEmpty })
    }

    /// The events from calendars shown always in the `days` days from today, for the weekly review,
    /// each once, under the stop `Timeline.stop(for:in:)` gives the day it starts on, or today. A
    /// stop with none is left out.
    public static func ahead(
        _ stops: [TimelineStop], _ events: [CalendarEvent], today: LocalDate, now: Date, days: Int = Timeline.reviewDays
    ) -> [(stop: TimelineStop, events: [CalendarEvent])] {
        let end = today.adding(days: days)
        let near = Dictionary(grouping: events.filter { $0.reach == .always && $0.firstDay < end }) {
            Timeline.stop(for: max($0.firstDay, today), in: stops)
        }
        return stops.compactMap { stop in
            let shown = Self.events(near[stop] ?? [], on: stop, today: today, now: now)
            return shown.isEmpty ? nil : (stop, shown)
        }
    }

    /// How many of a stop's events show before the rest are folded away.
    public static let shownFirst = 5

    /// The fewest events folded away: when fewer would be, they all show.
    public static let fewestFolded = 3

    /// The selection ID of the line that shows the rest of `stop`'s events, as a row of the list:
    /// the same each time for the same stop.
    public static func moreEventsID(for stop: TimelineStop) -> UUID {
        UUID(hashing: "more events \(stop.id)")
    }

    /// `events` as a stop shows them: the first `shownFirst`, and how many more are folded away
    /// after them; all of them when the stop's been opened out, or when fewer than `fewestFolded`
    /// would be folded.
    public static func folded<Event>(_ events: [Event], isOpenedOut: Bool) -> (shown: [Event], more: Int) {
        guard !isOpenedOut, events.count - shownFirst >= fewestFolded else { return (events, 0) }
        return (Array(events.prefix(shownFirst)), events.count - shownFirst)
    }

    /// The series that an event's identifier from its calendar belongs to: the identifier without
    /// the `/RID=` and number that a changed occurrence of a repeating event has, or the `_R` and
    /// date that Google Calendar adds to the part of a series split off from the rest.
    public static func seriesID(_ externalID: String) -> String {
        externalID
            .replacing(/\/RID=.*$/, with: "")
            .replacing(/_R\d{8}T\d{6}Z?(?=@|$)/, with: "")
    }

    /// Whether `item` is linked to the series `seriesID`.
    public static func isLinked(_ item: Item, to seriesID: String) -> Bool {
        guard let linked = item.calendarEventID, !seriesID.isEmpty else { return false }
        return Self.seriesID(linked) == Self.seriesID(seriesID)
    }

    /// The open note or task in Reference linked to the event's series; or, with none, the first
    /// made of those linked to another series that have the event's title, since a series can be
    /// started again under a new identifier when part of it is changed.
    public static func linkedNote(for event: CalendarEvent, in items: [Item]) -> Item? {
        guard !event.seriesID.isEmpty else { return nil }
        let linked = items.filter { $0.calendarEventID != nil && $0.bucket == .reference && $0.status == .open }
        if let note = linked.first(where: { isLinked($0, to: event.seriesID) }) { return note }
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return linked.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(title) == .orderedSame }
            .min { $0.createdAt < $1.createdAt }
    }

    /// The note linked to the event when it has open subtasks: the meeting whose things to raise
    /// go with the event.
    public static func meeting(for event: CalendarEvent, in items: [Item]) -> Item? {
        linkedNote(for: event, in: items).flatMap { openSubtasks(of: $0).isEmpty ? nil : $0 }
    }

    /// What an event's series can be linked to: the open notes and tasks in Reference, by title.
    public static func meetingNotes(in items: [Item]) -> [Item] {
        items.filter { $0.bucket == .reference && $0.status == .open }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The repeating events' series, each once as its first occurrence in `events`, by title.
    public static func series(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var seen: Set<String> = []
        return events.sorted { $0.start < $1.start }
            .filter { $0.isRecurring && !$0.seriesID.isEmpty && seen.insert($0.seriesID).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Links `note` to the series `seriesID`, taking the link off any other item, or with nil
    /// unlinks the series. Nil when nothing changes.
    @MainActor
    public static func link(_ note: Item?, to seriesID: String, in context: ModelContext, at now: Date = .now) -> Clarifier.Undo? {
        guard !seriesID.isEmpty else { return nil }
        let others = linked(to: seriesID, in: context).filter { $0.id != note?.id }
        let changing = [note].compactMap(\.self) + others
        let undo = Clarifier.Undo(changing, title: note?.title ?? others.first?.title ?? "")
        let before = changing.map(\.modifiedAt)
        for other in others { other.setCalendarEvent(nil, at: now) }
        note?.setCalendarEvent(seriesID, at: now)
        return changing.map(\.modifiedAt) == before ? nil : undo
    }

    /// The ID of the note made for the series `seriesID`: the same on every device, so two
    /// devices that each make one make the same record.
    public static func noteID(for seriesID: String) -> UUID {
        UUID(hashing: "note for event \(seriesID)")
    }

    /// Makes a note in Reference named like the event and linked to its series, taking the link
    /// off any other item. It takes the series' `noteID`, unless another item already has it.
    @MainActor
    public static func newMeetingNote(for event: CalendarEvent, in context: ModelContext, at now: Date = .now) -> (
        note: Item, undo: Clarifier.Undo
    ) {
        let others = event.seriesID.isEmpty ? [] : linked(to: event.seriesID, in: context)
        let note = NewRecord.item(in: .reference, in: context)
        if !event.seriesID.isEmpty {
            let id = noteID(for: event.seriesID)
            if (try? context.fetchCount(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id }))) == 0 { note.id = id }
        }
        let undo = Clarifier.Undo([note] + others, made: [note.recordID], title: event.title)
        for other in others { other.setCalendarEvent(nil, at: now) }
        note.kind = .note
        note.title = event.title
        note.calendarEventID = event.seriesID.isEmpty ? nil : event.seriesID
        return (note, undo)
    }

    @MainActor
    private static func linked(to seriesID: String, in context: ModelContext) -> [Item] {
        let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.calendarEventID != nil }))) ?? []
        return items.filter { isLinked($0, to: seriesID) }
    }

    /// The meeting's open subtasks, in their order.
    public static func openSubtasks(of meeting: Item) -> [Item] {
        (meeting.children ?? [])
            .filter { $0.status == .open && $0.bucket != .trash }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    private static func reaches(_ reach: CalendarReach, _ stop: TimelineStop) -> Bool {
        switch reach {
        case .always: true
        case .thisWeek: [.today, .day, .thisWeek].contains(stop.kind)
        case .off: false
        }
    }
}
