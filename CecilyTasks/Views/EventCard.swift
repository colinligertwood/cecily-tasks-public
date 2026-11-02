import SwiftData
import SwiftUI
import TasksCore
import WebKit

/// Which of an open event's notes show: those kept in its item, or those from its calendar.
private enum EventNotesTab: Hashable {
    case notes
    case calendar
}

/// An open event's notes, filling the rest of it, under a segmented control that chooses which:
/// **Notes**, kept in the item linked to it (`EventItemNotes`), or **Calendar**, its notes from
/// the calendar. Calendar can't be chosen when the calendar has no notes for it, and Notes can't
/// when the calendar doesn't identify the event, since it can't be linked.
struct EventNotesArea: View {
    let event: CalendarEvent
    var focusesOnOpen = false
    @Environment(AppModel.self) private var model
    /// The notes chosen, or nil for those the event starts with.
    @State private var chosen: EventNotesTab?

    var body: some View {
        let calendarNotes = CalendarFeed.shared.details(of: event)?.notes
        let canHaveNotes = !event.seriesID.isEmpty
        let shown = chosen ?? (canHaveNotes ? .notes : .calendar)
        VStack(alignment: .leading, spacing: Spacing.cardSpacing) {
            Divider()
            Picker("Notes", selection: Binding(get: { shown }, set: { chosen = $0 })) {
                Text("Notes")
                    .tag(EventNotesTab.notes)
                    .selectionDisabled(!canHaveNotes)
                Text("Calendar")
                    .tag(EventNotesTab.calendar)
                    .selectionDisabled(calendarNotes == nil)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            #if os(macOS)
                .fixedSize()
                .frame(maxWidth: .infinity)
            #endif
            switch shown {
            case .notes:
                EventItemNotes(container: model.container, event: event, focusesOnOpen: focusesOnOpen)
                    .id(event.seriesID)
            case .calendar:
                if let calendarNotes {
                    EventNotesView(notes: calendarNotes)
                } else {
                    Text("No notes from the calendar.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

/// An event's notes from its calendar, as a web page (`EventNotes.page`), which nothing outside
/// it can add to: no scripts, and nothing loaded from elsewhere. A clicked link opens in the
/// browser. It fills the space it's given, and scrolls.
private struct EventNotesView: View {
    let notes: String
    @State private var page: WebPage = {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.loadsSubresources = false
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        return WebPage(configuration: configuration, navigationDecider: LinksOpenOutside())
    }()

    var body: some View {
        WebView(page)
            .webViewContentBackground(.hidden)
            .task(id: notes) {
                do {
                    for try await _ in page.load(html: EventNotes.page(notes)) {}
                } catch {}
            }
    }
}

/// Lets the notes' own page load, and opens a link that's clicked in the browser instead.
private struct LinksOpenOutside: WebPage.NavigationDeciding {
    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async
        -> WKNavigationActionPolicy
    {
        guard let url = action.request.url, url.absoluteString != "about:blank" else { return .allow }
        if action.navigationType == .linkActivated {
            #if os(macOS)
                NSWorkspace.shared.open(url)
            #else
                await UIApplication.shared.open(url)
            #endif
        }
        return .cancel
    }
}

/// The open event's heading, as an open item's is: its title, with Join for its video meeting,
/// then its details as tags: whether it's cancelled, when it is, how it repeats, its calendar,
/// where it is, and the item it's linked to, whose tag has the choices of linking one.
private struct EventHeading: View {
    let event: CalendarEvent
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "reference" && $0.statusRaw == "open" }) private var notes: [Item]

    var body: some View {
        let details = CalendarFeed.shared.details(of: event)
        VStack(alignment: .leading, spacing: Spacing.cardSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                Text(event.displayTitle)
                    .font(.openTitle)
                    .strikethrough(event.isCancelled)
                    .foregroundStyle(event.isCancelled ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                JoinButton(event: event)
            }
            WrappingLayout(spacing: Spacing.large, lineSpacing: Spacing.tight) {
                if event.isCancelled {
                    TagView(tag: RowTag("Cancelled", symbol: "xmark.circle"))
                }
                TagView(tag: RowTag(event.fullWhen, symbol: "clock"))
                if let repeats = details?.repeats {
                    TagView(tag: RowTag(repeats, symbol: "repeat"))
                }
                if let calendar = CalendarFeed.shared.name(of: event.calendarID) {
                    Label {
                        Text(calendar)
                            .foregroundStyle(.secondary)
                    } icon: {
                        CalendarDot(calendarID: event.calendarID)
                    }
                    .font(.detail)
                    .lineLimit(1)
                }
                if let location = details?.location {
                    TagView(tag: RowTag(location, symbol: "mappin.and.ellipse"))
                        .frame(maxWidth: Self.locationWidth, alignment: .leading)
                }
                if !event.seriesID.isEmpty {
                    let linked = AgendaEvents.linkedNote(for: event, in: notes)
                    Menu {
                        EventItemChoices(event: event)
                    } label: {
                        if let linked {
                            TagView(tag: RowTag(linked.displayTitle, symbol: ItemField.meeting.symbol, spoken: "event item \(linked.displayTitle)"))
                        } else {
                            Label("Event Item", systemImage: ItemField.meeting.symbol)
                                .labelStyle(.iconOnly)
                                .font(.detail)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tagMenu()
                    .help("Event Item")
                }
            }
        }
    }

    /// The widest the location's tag gets; a longer location is cut short.
    private static let locationWidth: CGFloat = 360
}

/// "Join Teams", opening the event's video meeting, when it has one and isn't cancelled.
struct JoinButton: View {
    let event: CalendarEvent

    var body: some View {
        if !event.isCancelled, let link = CalendarFeed.shared.details(of: event)?.meetingLink {
            Link(destination: link.url) {
                Label("Join \(link.service)", systemImage: "video")
            }
            .buttonStyle(.bordered)
        }
    }
}

#if os(macOS)
    /// An event expanded over the list, laid out as an item's card is: its heading, its things to
    /// raise, then its notes filling the rest, with the cursor in them. Escape or its close
    /// button closes it.
    struct EventCard: View {
        let event: CalendarEvent
        @Environment(AppModel.self) private var model
        @State private var height: CGFloat = 600

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.cardSpacing) {
                EventHeading(event: event)
                    .padding(.trailing, 24)
                EventSubtasks(event: event, maxHeight: min(height / 3, 240))
                EventNotesArea(event: event, focusesOnOpen: true)
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                height = $0
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .cardChrome { model.openEvent = nil }
        }
    }
#else
    /// An event opened on iPhone, in a sheet laid out as an open item's is: its heading, its
    /// subtasks, Details for the rest of what the inspector shows, then its notes filling the
    /// rest.
    struct EventSheet: View {
        let event: CalendarEvent
        @Environment(AppModel.self) private var model
        @State private var height: CGFloat = 600

        var body: some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: Spacing.cardSpacing) {
                    EventHeading(event: event)
                    EventSubtasks(event: event, maxHeight: min(height / 3, 240))
                    NavigationLink {
                        Form { EventDetailsSections(event: event) }
                            .task { await CalendarFeed.shared.askForContacts() }
                            .navigationTitle("Details")
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    EventNotesArea(event: event)
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    height = $0
                }
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.openEvent = nil }
                    }
                }
            }
        }
    }
#endif
