import SwiftData
import SwiftUI
import TasksCore

extension CalendarEvent {
    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    /// For its row: "09:30–10:00", "All Day"; with the day, "Tue 12 Nov, 09:30" or "Tue 12 Nov";
    /// and for an all-day event of several days, "Until Thu 14 Nov".
    func when(showsDay: Bool) -> String {
        let day = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        if isAllDay {
            if lastDay != firstDay { return "Until \(lastDay.date(in: .current, hour: 12).formatted(day))" }
            return showsDay ? start.formatted(day) : "All Day"
        }
        if showsDay { return "\(start.formatted(day)), \(start.formatted(time))" }
        return "\(start.formatted(time))–\(end.formatted(time))"
    }

    /// In full, for its details: "Thursday 29 October, 10:00–10:30", "Thursday 29 October, All
    /// Day", "29 October to 31 October, All Day", or for a timed event over more than a day,
    /// "Thursday 29 October, 22:00 to Friday 30 October, 01:00".
    var fullWhen: String {
        let day = Date.FormatStyle().weekday(.wide).day().month(.wide)
        let date = Date.FormatStyle().day().month(.wide)
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        if isAllDay {
            if lastDay != firstDay {
                return "\(firstDay.date(in: .current, hour: 12).formatted(date)) to \(lastDay.date(in: .current, hour: 12).formatted(date)), All Day"
            }
            return "\(start.formatted(day)), All Day"
        }
        if lastDay != firstDay { return "\(start.formatted(day)), \(start.formatted(time)) to \(end.formatted(day)), \(end.formatted(time))" }
        return "\(start.formatted(day)), \(start.formatted(time))–\(end.formatted(time))"
    }
}

/// A calendar's colour as a small dot.
struct CalendarDot: View {
    let calendarID: String

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.caption2)
            .foregroundStyle(CalendarFeed.shared.color(of: calendarID) ?? .secondary)
            .accessibilityHidden(true)
    }
}

/// A selected event's context menu: Open Event, the inspector on the Mac, and the item it's
/// linked to.
struct EventMenu: View {
    let event: CalendarEvent
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open Event") { model.openEvent = event }
        #if os(macOS)
            Button(model.showsInspector ? "Hide Inspector" : "Show Inspector") {
                if !model.showsInspector { model.selection = [event.selectionID] }
                model.showsInspector.toggle()
            }
        #endif
        if !event.seriesID.isEmpty {
            Divider()
            Menu("Event Item", systemImage: ItemField.meeting.symbol) {
                EventItemChoices(event: event)
            }
        }
    }
}

/// What an event's series can be linked to: the items in Reference, the linked one ticked, with
/// Open, New Note (a note named like the event and linked to it) and Unlink.
struct EventItemChoices: View {
    let event: CalendarEvent
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "reference" && $0.statusRaw == "open" }) private var notes: [Item]

    var body: some View {
        let linked = AgendaEvents.linkedNote(for: event, in: notes)
        if let linked {
            Button("Open \(linked.displayTitle)") { model.openItem = linked.id }
            Divider()
        }
        ForEach(AgendaEvents.meetingNotes(in: notes)) { note in
            Toggle(
                note.displayTitle,
                isOn: Binding(
                    get: { note.id == linked?.id },
                    set: { model.linkMeeting($0 ? note : nil, to: event.seriesID) }))
        }
        Divider()
        Button("New Item") { model.newEventItem(for: event) }
        if let linked {
            Button("Unlink") { model.linkMeeting(nil, to: linked.calendarEventID ?? event.seriesID) }
        }
    }
}

/// An event's subtasks: those of the item it's linked to, as an open task's are. With no item
/// linked, its + offers New Note or a note in Reference, and starts a new
/// subtask under the one chosen.
struct EventSubtasks: View {
    let event: CalendarEvent
    let maxHeight: CGFloat
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "reference" && $0.statusRaw == "open" }) private var notes: [Item]

    var body: some View {
        if event.seriesID.isEmpty {
            Text("This calendar doesn't identify its events, so they can't have subtasks or notes.")
                .foregroundStyle(.secondary)
        } else if let note = AgendaEvents.linkedNote(for: event, in: notes) {
            SubtasksSection(task: note, maxHeight: maxHeight, offersOneAtATime: false)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Subtasks")
                        .font(.cardHeading)
                    Spacer()
                    Menu {
                        Button("New Item") { model.newSubtask(at: event, under: nil) }
                        let choices = AgendaEvents.meetingNotes(in: notes)
                        if !choices.isEmpty {
                            Section("Items in Reference") {
                                ForEach(choices) { note in
                                    Button(note.displayTitle) { model.newSubtask(at: event, under: note) }
                                }
                            }
                        }
                    } label: {
                        Label("New Subtask", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New Subtask")
                }
                .padding(.vertical, 6)
            }
        }
    }
}
