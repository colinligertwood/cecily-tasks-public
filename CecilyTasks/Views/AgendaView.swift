import SwiftData
import SwiftUI
import TasksCore

/// Agenda, today and what's ahead: a timeline of stops, today, the rest of this week,
/// next week, months and later, above the chosen stop's list: the calendars' events, the first
/// few with a line that shows the rest, what starts there, what's due, and what to follow up. An event linked to an item in Reference has
/// the note's open subtasks under it. In the weekly review, the next four weeks in one list, under
/// their stops. When the review has been missed, a line at the top offers to start it.
struct AgendaView: View {
    /// A new item being typed at the top of the list.
    @State private var draft: NewItemDraft?
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Item> { $0.statusRaw != "dropped" && $0.bucketRaw != "trash" }, animation: .default) private var items: [Item]
    @Query private var settings: [AppSettings]
    @Query private var reviews: [ReviewRecord]
    private let feed = CalendarFeed.shared
    /// The system's calendar, whose first day of the week the weeks start on.
    @Environment(\.calendar) private var calendar
    /// Which of the timeline's layouts fits the width: an index into `layouts`.
    @State private var fitted = 0
    /// The stops whose events have all been shown, rather than the first few.
    @State private var openedOut: Set<TimelineStop> = []
    /// When the missed-review line was last closed on this device, as seconds since 1970.
    @AppStorage("review-banner-closed") private var bannerClosed = 0.0

    var body: some View {
        if model.isReviewing {
            fourWeeks
        } else {
            timeline
        }
    }

    /// Whether to show the missed-review line: no review finished in two weeks, and the line not
    /// closed on this device in the last week.
    private var showsBanner: Bool {
        guard let first = settings.first else { return false }
        let now = Date.now
        guard now.timeIntervalSince1970 - bannerClosed >= 7 * 24 * 60 * 60 else { return false }
        return WeeklyReview.isMissed(reviews, firstLaunch: first.createdAt, now: now, boundary: model.boundary, in: .current)
    }

    @ViewBuilder private var timeline: some View {
        let layouts = Timeline.layouts(today: model.today, weekStart: calendar.firstWeekday)
        let stops = layouts[min(fitted, layouts.count - 1)]
        let chosen = chosenStop(in: stops)
        let placements = Timeline.placements(items, today: model.today, doneSince: model.dayStart, showsHidden: model.showsHidden)
        let parts = sections(of: chosen, placements)
        let events = AgendaEvents.events(feed.events, on: chosen, today: model.today, now: .now)
        let filled = Set(stops.filter { !sections(of: $0, placements).isEmpty })
            .union(AgendaEvents.filled(stops, feed.events, today: model.today, now: .now))
        VStack(spacing: 0) {
            if showsBanner {
                #if os(iOS)
                    Divider()
                #endif
                MissedReviewBanner { bannerClosed = Date.now.timeIntervalSince1970 }
            }
            #if os(macOS)
                if showsBanner { Divider() }
            #else
                Divider()
            #endif
            TimelineBar(stops: stops, today: model.today, filled: filled, chosen: chosen) { stop in
                choose(stop)
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                fitted = layouts.lastIndex { TimelineBar.width(of: $0) <= width } ?? 0
            }
            Divider()
            list(parts, events: events, of: chosen)
                .takesDraft(for: .list(.agenda), into: $draft)
                .overlay {
                    if draft == nil, parts.isEmpty && events.isEmpty {
                        EmptyList(
                            emptyTitle(chosen), symbol: Page.agenda.symbol,
                            description: chosen.kind == .today
                                ? "What's scheduled, due, or to follow up today appears here."
                                : "What's scheduled, due, or to follow up then appears here.")
                    }
                }
        }
        .navigationTitle(Page.agenda.rawValue)
        .onChange(of: model.timelineStep) { _, step in
            guard let step else { return }
            model.timelineStep = nil
            guard let index = stops.firstIndex(of: chosen), stops.indices.contains(index + step) else { return }
            choose(stops[index + step])
        }
    }

    /// Narrows the list to `stop`, clearing the selection.
    private func choose(_ stop: TimelineStop) {
        model.timelineStop = stop.kind == .today ? nil : stop
        model.selection = []
    }

    /// The next four weeks, under the stops of the widest layout that have something then.
    private var fourWeeks: some View {
        @Bindable var model = model
        let stops = Timeline.layouts(today: model.today, weekStart: calendar.firstWeekday).last ?? []
        let placements = Timeline.placements(items, today: model.today, doneSince: model.dayStart, showsHidden: model.showsHidden)
        let rowsByStop = Dictionary(
            Timeline.ahead(stops, placements, today: model.today)
                .map { ($0.stop, ListRow.rows($0.items, doneSince: model.dayStart) { $0.isIn(area: model.area) }) },
            uniquingKeysWith: +)
        let eventsByStop = Dictionary(
            AgendaEvents.ahead(stops, feed.events, today: model.today, now: .now).map { ($0.stop, $0.events) }, uniquingKeysWith: +)
        let sections = stops.map { stop in
            let events = AgendaEvents.folded(eventsByStop[stop] ?? [], isOpenedOut: openedOut.contains(stop))
            return (stop, events.shown, rowsByStop[stop] ?? [], events.more)
        }
        .filter { !$0.1.isEmpty || !$0.2.isEmpty }
        return List(selection: $model.selection) {
            ForEach(sections, id: \.0.id) { stop, events, rows, more in
                Section {
                    ForEach(events) { event in
                        EventRows(event: event, items: items, showsDay: stop.kind != .today && stop.kind != .day)
                    }
                    if more > 0 {
                        MoreEventsRow(count: more) { openOut(stop) }
                            .tag(AgendaEvents.moreEventsID(for: stop))
                    }
                    ForEach(rows) { row in
                        ItemRow(item: row.item, isSubItem: row.isSubItem, depth: row.depth, nestedUnder: row.under)
                            .tag(row.item.id)
                            #if os(iOS)
                                .startTodaySwipe(row.item)
                            #endif
                    }
                } header: {
                    Text(stop.heading(today: model.today))
                }
            }
        }
        .itemSelectionActions(
            items: sections.flatMap { $0.2.map(\.item) }, events: sections.flatMap(\.1),
            order: sections.flatMap { $0.1.map(\.selectionID) + moreEventsIDs(for: $0.0, more: $0.3) + $0.2.map(\.item.id) },
            actions: Dictionary(
                uniqueKeysWithValues: sections.filter { $0.3 > 0 }.map {
                    (AgendaEvents.moreEventsID(for: $0.0), openingOut($0.0, eventsByStop[$0.0] ?? []))
                })
        ) { chosen in
            DoneAndTrashMenu(items: chosen)
        }
        .listDraft(for: .list(.agenda), into: $draft)
        .overlay {
            if draft == nil, sections.isEmpty {
                EmptyList(
                    "Nothing in the Next Four Weeks", symbol: Page.agenda.symbol,
                    description: "What's scheduled, due, or to follow up in the next four weeks appears here.")
            }
        }
        .navigationTitle(Page.agenda.rawValue)
        #if os(macOS)
            .navigationSubtitle("Next Four Weeks")
        #endif
    }

    /// The chosen stop as the width lays it out: itself when it's there, or the one its first day
    /// is in, or Today.
    private func chosenStop(in stops: [TimelineStop]) -> TimelineStop {
        guard let chosen = model.timelineStop else { return stops[0] }
        if stops.contains(chosen) { return chosen }
        if chosen.kind == .later { return stops[stops.count - 1] }
        return Timeline.stop(for: chosen.first, in: stops) ?? stops[0]
    }

    /// The stop's parts, by the day that puts them there, as rows: those at the top in the area
    /// the lists are narrowed to, with what's nested under them. Empty parts are left out.
    private func sections(of stop: TimelineStop, _ placements: [TimelinePlacement]) -> [(ItemField, [ListRow])] {
        let parts = Timeline.parts(of: stop, placements, today: model.today)
        let fields = [(ItemField.scheduled, parts.starts), (.due, parts.due), (.followUp, parts.followUp)]
        let computed = fields.map { ListRow.rows($0.1, doneSince: model.dayStart) { $0.isIn(area: model.area) } }
        return zip(fields.map(\.0), model.settled(computed)).map { ($0, $1) }.filter { !$0.1.isEmpty }
    }

    /// A stop's part, which rows from another part can't be moved into: the day that puts them
    /// there is a different one.
    private static func dropGroup(_ field: ItemField) -> DropGroup {
        DropGroup(id: "agenda-\(field)", headings: [])
    }

    /// A stop's part's heading.
    private static func heading(_ field: ItemField) -> String {
        field == .followUp ? "Follow-Ups" : field.placeholder
    }

    /// Shows all of the stop's events. When the line that shows them is selected, `first`, the
    /// first of those it shows, is selected in its place.
    private func openOut(_ stop: TimelineStop, first: CalendarEvent? = nil) {
        withAnimation {
            _ = openedOut.insert(stop)
            if let first, model.selection == [AgendaEvents.moreEventsID(for: stop)] { model.selection = [first.selectionID] }
        }
    }

    /// Opening out the stop's events, from the line that shows them, given all of them.
    private func openingOut(_ stop: TimelineStop, _ events: [CalendarEvent]) -> () -> Void {
        let first = events.count > AgendaEvents.shownFirst ? events[AgendaEvents.shownFirst] : nil
        return { openOut(stop, first: first) }
    }

    /// The line that shows the rest of the stop's events, as a row of the list, when some are
    /// folded away.
    private func moreEventsIDs(for stop: TimelineStop, more: Int) -> [UUID] {
        more > 0 ? [AgendaEvents.moreEventsID(for: stop)] : []
    }

    private func list(_ sections: [(ItemField, [ListRow])], events all: [CalendarEvent], of stop: TimelineStop) -> some View {
        @Bindable var model = model
        let events = AgendaEvents.folded(all, isOpenedOut: openedOut.contains(stop))
        return List(selection: $model.selection) {
            if !events.shown.isEmpty {
                Section {
                    ForEach(events.shown) { event in
                        EventRows(event: event, items: items, showsDay: stop.kind != .today && stop.kind != .day)
                    }
                    if events.more > 0 {
                        MoreEventsRow(count: events.more) { openOut(stop) }
                            .tag(AgendaEvents.moreEventsID(for: stop))
                    }
                } header: {
                    GroupHeading("Calendar", symbol: ItemField.meeting.symbol)
                }
            }
            // A new item's row, after the events, where the item lands among the stop's items.
            if draft != nil {
                Section {
                    DraftRow(draft: $draft)
                }
            }
            ForEach(sections, id: \.0) { field, rows in
                Section {
                    ForEach(rows) { row in
                        ItemRow(item: row.item, isSubItem: row.isSubItem, depth: row.depth, nestedUnder: row.under)
                            .tag(row.item.id)
                            .subItemDragging(row, group: Self.dropGroup(field))
                            #if os(iOS)
                                .startTodaySwipe(row.item)
                            #endif
                    }
                    .dropsBetween(rows, model: model, group: Self.dropGroup(field))
                } header: {
                    GroupHeading(Self.heading(field), symbol: field.symbol)
                }
            }
        }
        .itemSelectionActions(
            items: sections.flatMap { $0.1.map(\.item) }, events: events.shown,
            order: events.shown.map(\.selectionID) + moreEventsIDs(for: stop, more: events.more) + sections.flatMap { $0.1.map(\.item.id) },
            arrangeable: sections.map(\.1),
            actions: events.more > 0 ? [AgendaEvents.moreEventsID(for: stop): openingOut(stop, all)] : [:]
        ) { chosen in
            DoneAndTrashMenu(items: chosen)
        }
    }

    /// "Nothing for Today", "Nothing on Wednesday", "Nothing Next Week", "Nothing in November".
    private func emptyTitle(_ stop: TimelineStop) -> String {
        switch stop.kind {
        case .today: "Nothing for Today"
        case .day: "Nothing on \(stop.first.date(in: .current, hour: 12).formatted(.dateTime.weekday(.wide)))"
        case .thisWeek: "Nothing This Week"
        case .nextWeek: "Nothing Next Week"
        case .month: "Nothing in \(stop.first.date(in: .current, hour: 12).formatted(.dateTime.month(.wide)))"
        case .later: "Nothing Later"
        }
    }
}

/// A line across the list where a stop's events are folded away, saying how many more there
/// are, that shows them when it's clicked.
private struct MoreEventsRow: View {
    let count: Int
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(spacing: Spacing.small) {
                line
                Label("\(count) more events", systemImage: "chevron.down")
                    .font(.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                line
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Show \(count) more events")
    }

    private var line: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
    }
}

/// A calendar event's row, in columns that line up from row to row: a dot in its calendar's
/// colour and its title (struck through and grey when it's cancelled), how many things there are
/// to raise at it, its calendar's name, and when it is. Each column is as wide as the longest text
/// it can hold; on iPhone the calendar's name is under the title instead. It's selected and opened
/// like an item's row, and its subtasks are in the open event. `showsDay` adds the day, for
/// stops longer than a day.
private struct EventRows: View {
    let event: CalendarEvent
    let items: [Item]
    let showsDay: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.large) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                RowMark { CalendarDot(calendarID: event.calendarID) }
                #if os(macOS)
                    title
                #else
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        title
                        if let calendar {
                            Text(calendar)
                                .font(.detail)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .leading) {
                SubtaskCount(tag: Self.countTag(99), font: .rowTitle).hidden()
                if let count { SubtaskCount(tag: Self.countTag(count), font: .rowTitle) }
            }
            #if os(macOS)
                column(calendar ?? "", widest: CalendarFeed.shared.calendars.map(\.title), alignment: .leading)
                    .frame(maxWidth: Self.calendarColumnWidth, alignment: .leading)
            #endif
            column(event.when(showsDay: showsDay), widest: Self.widestWhen(showsDay: showsDay), alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.vertical, Spacing.rowPadding)
        .listRowSeparator(.hidden)
        .tag(event.selectionID)
    }

    private var calendar: String? { CalendarFeed.shared.name(of: event.calendarID) }

    /// The widest the calendar column gets; longer names are cut short.
    private static let calendarColumnWidth: CGFloat = 160

    private var title: some View {
        Text(event.displayTitle)
            .font(.rowTitle)
            .strikethrough(event.isCancelled)
            .foregroundStyle(event.isCancelled ? .secondary : .primary)
    }

    /// How many things there are to raise at it, when there are any.
    private var count: Int? {
        AgendaEvents.meeting(for: event, in: items).map { AgendaEvents.openSubtasks(of: $0).count }
    }

    private static func countTag(_ count: Int) -> RowTag {
        RowTag("\(count)", symbol: "checklist", spoken: count == 1 ? "1 subtask" : "\(count) subtasks")
    }

    /// `text` in grey, in a column as wide as the widest of `widest`, so it lines up with the same
    /// column in other rows.
    private func column(_ text: String, widest: [String], alignment: Alignment) -> some View {
        ZStack(alignment: alignment) {
            ForEach(widest.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { Text($0).hidden() }
            Text(text)
        }
        .font(.detail)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// The longest texts `CalendarEvent.when(showsDay:)` can give, in the current locale: a
    /// Wednesday in September at 23:59, all day, until then, or between two late times.
    private static func widestWhen(showsDay: Bool) -> [String] {
        let day = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let sample = DateComponents(calendar: .current, year: 2026, month: 9, day: 30, hour: 23, minute: 58).date ?? .now
        let late = sample.addingTimeInterval(-11 * 3600)
        if showsDay { return ["\(sample.formatted(day)), \(sample.formatted(time))", "Until \(sample.formatted(day))"] }
        return ["\(late.formatted(time))–\(sample.formatted(time))", "All Day", "Until \(sample.formatted(day))"]
    }
}

/// One line saying the weekly review is overdue, with Start Review and a close button.
private struct MissedReviewBanner: View {
    let close: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Label("No weekly review for 2 weeks", systemImage: "checklist.unchecked")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Start Review") { model.startReview() }
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

extension TimelineStop {
    /// The stop as a heading: "Today", "Tomorrow", "Wednesday", "This Week", "Next Week",
    /// "November", or "Later".
    func heading(today: LocalDate) -> String {
        let date = first.date(in: .current, hour: 12)
        switch kind {
        case .today: return "Today"
        case .day where today.days(to: first) == 1: return "Tomorrow"
        case .day: return date.formatted(.dateTime.weekday(.wide))
        case .thisWeek: return "This Week"
        case .nextWeek: return "Next Week"
        case .month: return first.year == today.year ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.month(.wide).year())
        case .later: return "Later"
        }
    }
}

/// Agenda's stops in a row, the days, the weeks, the months and Later each set apart by a thin
/// line, with a dot under those that have something. Choosing one narrows the list to it; rows
/// dropped on one start on its first day, except on Later.
private struct TimelineBar: View {
    let stops: [TimelineStop]
    let today: LocalDate
    let filled: Set<TimelineStop>
    let chosen: TimelineStop
    let choose: (TimelineStop) -> Void

    private static let spacing: CGFloat = 4
    private static let margin: CGFloat = 16

    /// The width the stops need, with a separator between the days, the weeks, the months and Later.
    static func width(of stops: [TimelineStop]) -> CGFloat {
        let separators = zip(stops, stops.dropFirst()).count { group(of: $0.kind) != group(of: $1.kind) }
        return stops.map { width(of: $0.kind) }.reduce(0, +) + spacing * CGFloat(stops.count - 1 + separators) + CGFloat(separators)
            + 2 * margin
    }

    /// Which of the days, the weeks, the months and Later a stop is among.
    private static func group(of kind: TimelineStop.Kind) -> Int {
        switch kind {
        case .today, .day: 0
        case .thisWeek, .nextWeek: 1
        case .month: 2
        case .later: 3
        }
    }

    private static func width(of kind: TimelineStop.Kind) -> CGFloat {
        switch kind {
        case .today, .day: 40
        case .thisWeek, .nextWeek: 84
        case .month, .later: 56
        }
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                if index > 0, Self.group(of: stops[index - 1].kind) != Self.group(of: stop.kind) {
                    Divider()
                        .frame(height: 28)
                }
                StopView(stop: stop, today: today, isFilled: filled.contains(stop), isChosen: stop == chosen) { choose(stop) }
                    .frame(width: Self.width(of: stop.kind))
            }
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// One stop: a caption, its name, and a dot when it has something. It takes dropped rows.
private struct StopView: View {
    let stop: TimelineStop
    let today: LocalDate
    let isFilled: Bool
    let isChosen: Bool
    let choose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 2) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(label)
                    .fontWeight(stop.kind == .today ? .semibold : .regular)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: Spacing.indexChipHeight)
                    .foregroundStyle(isChosen ? Color.white : stop.kind == .today ? Color.accentColor : Color.primary)
                    .background(isChosen ? Color.accentColor : Color.clear, in: Capsule())
                    .dropHighlight(isTargeted, in: Capsule())
                Circle()
                    .fill(isFilled ? Color.secondary : Color.clear)
                    .frame(width: Spacing.indexDot, height: Spacing.indexDot)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .dropDestination(for: String.self) { payloads, _ in
            guard stop.kind != .later else { return false }
            return model.start(dragged: payloads, on: stop.first)
        } isTargeted: { over in
            isTargeted = over && stop.kind != .later
        }
    }

    private func date(_ day: LocalDate) -> Date { day.date(in: .current, hour: 12) }

    /// "Today", a day's short weekday, a week's dates, or January's year.
    private var caption: String {
        switch stop.kind {
        case .today: "Today"
        case .day: date(stop.first).formatted(.dateTime.weekday(.abbreviated))
        case .thisWeek, .nextWeek: dates
        case .month: stop.first.month == 1 ? String(stop.first.year) : " "
        case .later: " "
        }
    }

    /// The day of the month, "This Week", "Next Week", the month's short name, or "Later".
    private var label: String {
        switch stop.kind {
        case .today, .day: date(stop.first).formatted(.dateTime.day())
        case .thisWeek: "This Week"
        case .nextWeek: "Next Week"
        case .month: date(stop.first).formatted(.dateTime.month(.abbreviated))
        case .later: "Later"
        }
    }

    /// "2–8 Nov", or "30 Nov – 6 Dec" across two months.
    private var dates: String {
        let last = stop.last ?? stop.first
        let end = date(last).formatted(.dateTime.day().month(.abbreviated))
        if last.month == stop.first.month { return "\(date(stop.first).formatted(.dateTime.day()))–\(end)" }
        return "\(date(stop.first).formatted(.dateTime.day().month(.abbreviated))) – \(end)"
    }

    private var name: String {
        switch stop.kind {
        case .today: "Today"
        case .day where today.days(to: stop.first) == 1: "Tomorrow"
        case .day: date(stop.first).formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .thisWeek: "This week, \(dates)"
        case .nextWeek: "Next week, \(dates)"
        case .month: date(stop.first).formatted(.dateTime.month(.wide).year())
        case .later: "Later"
        }
    }
}

#Preview(traits: .previewRecords) {
    NavigationStack { AgendaView() }
}
