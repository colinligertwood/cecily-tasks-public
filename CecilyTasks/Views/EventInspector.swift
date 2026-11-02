import SwiftData
import SwiftUI
import TasksCore

extension EventPerson.Reply {
    /// The heading of the people who replied so.
    var name: String {
        switch self {
        case .accepted: "Accepted"
        case .maybe: "Maybe"
        case .declined: "Declined"
        case .noResponse: "No Response"
        }
    }
}

/// An event's details, as sections of a form: when it is, how it repeats and its calendar; where
/// it is and its link; your reply; the item it's linked to; and its people, the organiser
/// first, then the rooms, then the others by their reply. A detail it doesn't have is left out.
struct EventDetailsSections: View {
    let event: CalendarEvent
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "reference" && $0.statusRaw == "open" }) private var notes: [Item]

    var body: some View {
        let details = CalendarFeed.shared.details(of: event)
        Section {
            DetailRow("When", symbol: "clock") {
                Text(event.fullWhen)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(event.fullWhen)
            }
            if let moved = details?.movedFrom {
                DetailRow("Moved From", symbol: "arrow.uturn.backward") { Text(moved.formatted(Self.dayAndTime)).multilineTextAlignment(.trailing) }
            } else if details?.isChanged == true {
                Label("Changed from the rest of the series", systemImage: "pencil")
                    .foregroundStyle(.secondary)
            }
            if let repeats = details?.repeats {
                DetailRow("Repeats", symbol: "repeat") { Text(repeats) }
            }
            DetailRow("Calendar", symbol: "calendar") {
                HStack(spacing: Spacing.small) {
                    CalendarDot(calendarID: event.calendarID)
                    Text(CalendarFeed.shared.name(of: event.calendarID) ?? "")
                }
                .help(details?.account ?? "")
            }
            if let you = details?.people.you {
                DetailRow("Your Reply", symbol: "envelope") { Text(you.reply.name) }
            }
        }
        if details?.location != nil || details?.url != nil {
            Section {
                if let location = details?.location {
                    DetailRow("Location", symbol: "mappin.and.ellipse") { Text(location).textSelection(.enabled).multilineTextAlignment(.trailing) }
                }
                if let url = details?.url, url != details?.meetingLink?.url {
                    DetailRow("Link", symbol: "link") { Link(url.host() ?? url.absoluteString, destination: url) }
                }
            }
        }
        if !event.seriesID.isEmpty {
            Section {
                DetailRow("Event Item", symbol: ItemField.meeting.symbol) {
                    Menu(AgendaEvents.linkedNote(for: event, in: notes).map { $0.displayTitle } ?? "None") {
                        EventItemChoices(event: event)
                    }
                    .fixedSize()
                }
            }
        }
        if let organizer = details?.people.organizer {
            Section("Organizer") { PersonRow(person: organizer) }
        }
        if let rooms = details?.people.rooms, !rooms.isEmpty {
            Section("Rooms") {
                ForEach(rooms) { PersonRow(person: $0) }
            }
        }
        ForEach(details?.people.groups ?? []) { group in
            Section("\(group.reply.name) (\(group.people.count))") {
                ForEach(group.people) { PersonRow(person: $0) }
            }
        }
    }

    /// "Thursday 29 October, 10:00".
    private static let dayAndTime = Date.FormatStyle().weekday(.wide).day().month(.wide).hour().minute()
}

/// The event's video meeting, named by its service, with its address as a link that joins it;
/// nothing when it has none or is cancelled.
private struct MeetingLinkRow: View {
    let event: CalendarEvent

    var body: some View {
        if !event.isCancelled, let link = CalendarFeed.shared.details(of: event)?.meetingLink {
            DetailRow(link.service, symbol: "video") {
                Link((link.url.host(percentEncoded: false) ?? "") + link.url.path(percentEncoded: false), destination: link.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(link.url.absoluteString)
            }
        }
    }
}

/// A row of an event's details: its name with a symbol, as an item's details are, and its value.
private struct DetailRow<Value: View>: View {
    let name: String
    let symbol: String
    @ViewBuilder let value: Value

    init(_ name: String, symbol: String, @ViewBuilder value: () -> Value) {
        self.name = name
        self.symbol = symbol
        self.value = value()
    }

    var body: some View {
        LabeledContent {
            value
        } label: {
            Label(name, systemImage: symbol)
                .labelStyle(DetailLabelStyle())
        }
    }
}

/// Someone invited: their name, with their email address under it, and whether they're
/// optional.
private struct PersonRow: View {
    let person: EventPerson

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.isYou ? "\(person.displayName) (you)" : person.displayName)
                if person.name != nil, let email = person.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            if person.isOptional {
                Spacer()
                Text("Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The inspector's view of a selected event: its title (struck through and grey when it's
/// cancelled), a way to join its video meeting, and its details, read-only.
struct EventInspector: View {
    let event: CalendarEvent

    var body: some View {
        Form {
            Section {
                Text(event.displayTitle)
                    .font(.panelTitle)
                    .strikethrough(event.isCancelled)
                    .foregroundStyle(event.isCancelled ? .secondary : .primary)
                    .textSelection(.enabled)
                MeetingLinkRow(event: event)
            }
            EventDetailsSections(event: event)
        }
        .formStyle(.grouped)
        .task { await CalendarFeed.shared.askForContacts() }
    }
}
