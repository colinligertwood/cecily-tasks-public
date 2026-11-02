import Contacts
import EventKit
import SwiftUI
import TasksCore

/// The device's calendars and their events from today on, read with EventKit for Agenda.
/// It's off until it's turned on in Settings, which asks for access to the
/// calendars. Whether it's on and how far ahead each calendar is shown are kept on the device,
/// since a calendar's identifier is the device's own. It reads the events again when the
/// calendars change and when `reload()` or `refresh()` is called.
@MainActor @Observable
final class CalendarFeed {
    static let shared = CalendarFeed()

    enum Access {
        case notAsked, granted, refused
    }

    struct CalendarInfo: Identifiable {
        let id: String
        let title: String
        /// The account it's in: iCloud, Google, Exchange and so on.
        let account: String
        let color: Color
        let reach: CalendarReach
    }

    private(set) var isOn: Bool
    /// How often, in minutes, the calendars' accounts are asked for what's changed while the app
    /// is open, as well as when it comes to the front.
    private(set) var checkMinutes: Int
    /// The intervals Settings offers, in minutes.
    static let checkIntervals = [1, 5, 15, 30]
    private(set) var access: Access
    /// Every calendar, by account and then by title.
    private(set) var calendars: [CalendarInfo] = []
    /// The events of the calendars that are shown, from yesterday to `AgendaEvents.daysAhead` days ahead.
    private(set) var events: [CalendarEvent] = []
    /// Goes up when the people's names can be read from Contacts, so details are read again.
    private(set) var namesRevision = 0

    /// What the inspector shows of an event, read from Calendar.
    struct Details {
        let account: String?
        let location: String?
        let url: URL?
        /// As the calendar has them: plain text, or HTML.
        let notes: String?
        /// How it repeats: "Every Thursday".
        let repeats: String?
        let people: EventPeople
        /// The link that joins its video meeting, from its link, location or notes.
        let meetingLink: MeetingLink?
        /// For an occurrence moved from its series' usual time, that time.
        let movedFrom: Date?
        /// Whether the occurrence was changed from the rest of its series.
        let isChanged: Bool
    }

    @ObservationIgnored private let store = EKEventStore()
    private static let contacts = CNContactStore()
    /// The EventKit event of each of `events`, by its ID.
    @ObservationIgnored private var eventKitEvents: [String: EKEvent] = [:]
    /// Each event's details, read the first time they're asked for, until the events are read again.
    @ObservationIgnored private var detailsRead: [String: Details] = [:]
    /// Each of `events` by its selection ID.
    @ObservationIgnored private var bySelectionID: [UUID: CalendarEvent] = [:]
    /// Each calendar's reach that isn't the one it starts with, by identifier.
    @ObservationIgnored private var reaches: [String: String]
    /// Whether the system is asking for access to the calendars now.
    @ObservationIgnored private var isAsking = false
    private static let onKey = "calendar-events-on"
    private static let reachesKey = "calendar-reaches"
    private static let checkKey = "calendar-check-minutes"

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.onKey)
        let minutes = UserDefaults.standard.integer(forKey: Self.checkKey)
        checkMinutes = Self.checkIntervals.contains(minutes) ? minutes : 1
        reaches = UserDefaults.standard.dictionary(forKey: Self.reachesKey) as? [String: String] ?? [:]
        access = Self.currentAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        askIfNeeded()
    }

    /// Turns the events on or off, asking for access if it hasn't been asked for.
    func setOn(_ on: Bool) {
        isOn = on
        UserDefaults.standard.set(on, forKey: Self.onKey)
        reload()
        askIfNeeded()
    }

    /// Asks for access to the calendars while the events are on and it hasn't been asked for: the
    /// first time they're turned on, and for a copy of the app that's signed differently from the
    /// one that turned them on, which the system asks about afresh.
    func askIfNeeded() {
        guard isOn, !isAsking, Self.currentAccess() == .notAsked else { return }
        isAsking = true
        store.requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                CalendarFeed.shared.isAsking = false
                CalendarFeed.shared.reload()
                await CalendarFeed.shared.askForContacts()
            }
        }
    }

    /// Asks for access to Contacts, for the people's names, if it hasn't been asked for, and reads
    /// the details again when it's given.
    func askForContacts() async {
        guard isShowing, CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        guard (try? await Self.contacts.requestAccess(for: .contacts)) == true else { return }
        detailsRead = [:]
        namesRevision += 1
    }

    func setCheckMinutes(_ minutes: Int) {
        checkMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: Self.checkKey)
    }

    func setReach(_ reach: CalendarReach, of calendarID: String) {
        reaches[calendarID] = reach == .initial ? nil : reach.rawValue
        UserDefaults.standard.set(reaches, forKey: Self.reachesKey)
        reload()
    }

    /// Asks the calendars' accounts for what's changed, which the store announces when it has it,
    /// and reads the calendars and their events again now.
    func refresh() {
        if isOn, Self.currentAccess() == .granted { store.refreshSourcesIfNecessary() }
        reload()
        askIfNeeded()
    }

    /// Reads the calendars and their events again.
    func reload() {
        access = Self.currentAccess()
        eventKitEvents = [:]
        detailsRead = [:]
        bySelectionID = [:]
        guard isOn, access == .granted else {
            calendars = []
            events = []
            return
        }
        let found = store.calendars(for: .event)
        calendars = found.map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "",
                color: Color(cgColor: calendar.cgColor), reach: reach(of: calendar.calendarIdentifier))
        }
        .sorted { a, b in
            a.account != b.account
                ? a.account.localizedStandardCompare(b.account) == .orderedAscending
                : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let shown = found.filter { reach(of: $0.calendarIdentifier) != .off }
        guard !shown.isEmpty else {
            events = []
            return
        }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now)) ?? .now
        let end = calendar.date(byAdding: .day, value: AgendaEvents.daysAhead, to: start) ?? .now
        events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: shown)).map { event in
            let calendarID = event.calendar?.calendarIdentifier ?? ""
            let made = CalendarEvent(
                id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)", title: event.title ?? "",
                start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, calendarID: calendarID, reach: reach(of: calendarID),
                seriesID: AgendaEvents.seriesID(event.calendarItemExternalIdentifier ?? ""), isRecurring: event.hasRecurrenceRules,
                isCancelled: event.status == .canceled, in: calendar)
            eventKitEvents[made.id] = event
            bySelectionID[made.selectionID] = made
            return made
        }
    }

    /// The event whose row has the selection ID `id`.
    func event(withSelectionID id: UUID) -> CalendarEvent? {
        bySelectionID[id]
    }

    /// The event's details from Calendar, while it's read.
    func details(of event: CalendarEvent) -> Details? {
        _ = namesRevision
        if let read = detailsRead[event.id] { return read }
        guard let found = eventKitEvents[event.id] else { return nil }
        let details = Self.details(of: found)
        detailsRead[event.id] = details
        return details
    }

    private static func details(of found: EKEvent) -> Details {
        let location = found.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let notes = found.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let original = found.isDetached ? found.occurrenceDate : nil
        let people = EventPeople(organizer: found.organizer.map(Self.person), attendees: (found.attendees ?? []).map(Self.person))
        let meetingLink = MeetingLink.find(in: [found.url?.absoluteString, location, notes])
        return Details(
            account: found.calendar?.source?.title,
            location: location.flatMap { EventLocation.shown($0, rooms: people.rooms, meeting: meetingLink) }, url: found.url, notes: notes,
            repeats: found.recurrenceRules?.first.flatMap(Self.recurrence)?.summary,
            people: people,
            meetingLink: meetingLink,
            movedFrom: original.flatMap { abs($0.timeIntervalSince(found.startDate)) >= 60 ? $0 : nil }, isChanged: found.isDetached)
    }

    private static func person(_ participant: EKParticipant) -> EventPerson {
        let reply: EventPerson.Reply =
            switch participant.participantStatus {
            case .accepted, .completed, .inProcess: .accepted
            case .tentative: .maybe
            case .declined: .declined
            default: .noResponse
            }
        let email = participant.url.scheme?.lowercased() == "mailto" ? (participant.url as NSURL).resourceSpecifier : nil
        return EventPerson(
            name: contactName(of: participant) ?? participant.name, email: email, reply: reply, isYou: participant.isCurrentUser,
            isOptional: participant.participantRole == .optional,
            isRoom: participant.participantType == .room || participant.participantType == .resource)
    }

    /// The person's name as it is in Contacts, when they're there and Contacts can be read.
    private static func contactName(of participant: EKParticipant) -> String? {
        #if os(macOS)
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        #else
            guard [.authorized, .limited].contains(CNContactStore.authorizationStatus(for: .contacts)) else { return nil }
        #endif
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        guard let contact = try? contacts.unifiedContacts(matching: participant.contactPredicate, keysToFetch: keys).first else { return nil }
        return CNContactFormatter.string(from: contact, style: .fullName)
    }

    /// An EventKit repeat rule as a `Recurrence`, for its summary.
    private static func recurrence(_ rule: EKRecurrenceRule) -> Recurrence? {
        let frequency: Recurrence.Frequency =
            switch rule.frequency {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            @unknown default: .daily
            }
        let days = (rule.daysOfTheWeek ?? []).compactMap { day in
            Recurrence.Weekday(rawValue: day.dayOfTheWeek.rawValue).map { Recurrence.WeekdayNumber($0, day.weekNumber == 0 ? nil : day.weekNumber) }
        }
        let end: Recurrence.End =
            if let date = rule.recurrenceEnd?.endDate {
                .until(LocalDate(date, in: .current))
            } else if let count = rule.recurrenceEnd?.occurrenceCount, count > 0 {
                .count(count)
            } else {
                .never
            }
        return Recurrence(
            frequency, interval: max(rule.interval, 1), byDay: days, byMonthDay: (rule.daysOfTheMonth ?? []).map(\.intValue),
            byMonth: (rule.monthsOfTheYear ?? []).map(\.intValue), bySetPosition: (rule.setPositions ?? []).map(\.intValue),
            weekStart: Recurrence.Weekday(rawValue: rule.firstDayOfTheWeek) ?? .monday, end: end)
    }

    /// Whether events are read: they're on and the calendars can be read.
    var isShowing: Bool { isOn && access == .granted }

    /// The repeating events a meeting's note can be linked to, each once, by title.
    var series: [CalendarEvent] { AgendaEvents.series(events) }

    /// The title of the series with `id`, when one of its events is read.
    func title(ofSeries id: String) -> String? {
        let series = AgendaEvents.seriesID(id)
        return events.first { $0.seriesID == series }?.title
    }

    /// The colour of the calendar with `id`.
    func color(of id: String) -> Color? {
        calendars.first { $0.id == id }?.color
    }

    /// The name of the calendar with `id`.
    func name(of id: String) -> String? {
        calendars.first { $0.id == id }?.title
    }

    private func reach(of id: String) -> CalendarReach {
        reaches[id].flatMap(CalendarReach.init(rawValue:)) ?? .initial
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .refused
        }
    }
}

extension String {
    /// Nil when it's empty.
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
