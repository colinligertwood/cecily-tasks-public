import SwiftData
import SwiftUI
import TasksCore

/// What can be done now: the actions in Actions today, grouped by context
/// unless the View menu says otherwise, and narrowed by its filters and the area filter. Each
/// action is in every one of its contexts. In the weekly review, those unchanged for two weeks.
struct ActionsView: View {
    /// A new item being typed at the top of the list.
    @State private var draft: NewItemDraft?
    @Environment(AppModel.self) private var model
    @AppStorage(ActionsGrouping.key) private var grouping = ActionsGrouping.context
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "action" && $0.statusRaw != "dropped" }, animation: .default) private var actions: [Item]

    var body: some View {
        if model.isReviewing {
            UnchangedActions(actions: actions)
        } else {
            grouped
        }
    }

    @ViewBuilder private var grouped: some View {
        @Bindable var model = model
        let groups = ActionsList.groups(
            actions, by: grouping, filter: model.actionsFilter, today: model.today, doneSince: model.dayStart, showsHidden: model.showsHidden,
            keeping: model.keptWhileSettling)
        let computed = groups.map { ListRow.rows($0.items, doneSince: model.dayStart) { $0.isIn(area: model.area) } }
        let rows = zip(groups, model.settled(computed)).map { ($0, $1) }.filter { !$0.1.isEmpty }
        List(selection: $model.selection) {
            ForEach(rows, id: \.0.id) { group, rows in
                // A section with nothing to head it has no header.
                if case .all = group.heading {
                    Section {
                        sectionRows(rows, group: group)
                    }
                } else {
                    Section {
                        sectionRows(rows, group: group)
                    } header: {
                        ActionsGroupHeading(heading: group.heading)
                    }
                }
            }
        }
        .itemSelectionActions(items: rows.flatMap { $0.1.map(\.item) }, arrangeable: rows.map(\.1)) { chosen in
            DoneAndTrashMenu(items: chosen)
        }
        .listDraft(for: .list(.actions), into: $draft)
        .overlay {
            if draft == nil, rows.isEmpty {
                if model.actionsFilter.isEmpty {
                    EmptyList("No Actions", symbol: Page.actions.symbol, description: "Next steps you've decided on appear here.")
                } else {
                    EmptyList("Nothing Fits", symbol: "line.3.horizontal.decrease.circle", description: "No actions match the filters.") {
                        Button("Clear Filters") { model.actionsFilter = ActionsFilter() }
                    }
                }
            }
        }
        .navigationTitle(Page.actions.rawValue)
        #if os(macOS)
            .navigationSubtitle(model.actionsFilter.summary)
        #endif
    }

    private func sectionRows(_ rows: [ListRow], group: ListGroup) -> some View {
        ForEach(rows) { row in
            ItemRow(item: row.item, isSubItem: row.isSubItem, depth: row.depth, nestedUnder: row.under)
                .tag(row.item.id)
                .subItemDragging(row, group: group.dropGroup)
                #if os(iOS)
                    .startTodaySwipe(row.item)
                #endif
        }
        .dropsBetween(rows, model: model, group: group.dropGroup)
    }
}

/// Actions in the weekly review: those not changed in two weeks, the one changed longest ago
/// first, each with how long it's been, in the area the lists are narrowed to.
private struct UnchangedActions: View {
    /// A new item being typed at the top of the list.
    @State private var draft: NewItemDraft?
    let actions: [Item]
    @Environment(AppModel.self) private var model

    static let subtitle = "Unchanged in 2 Weeks, Oldest First"

    var body: some View {
        @Bindable var model = model
        let shown = ActionsList.unchanged(
            actions, today: model.today, boundary: model.boundary, in: .current, doneSince: model.dayStart, showsHidden: model.showsHidden
        )
        .filter { $0.isIn(area: model.area) }
        List(selection: $model.selection) {
            Section {
                ForEach(shown) { item in
                    ItemRow(item: item, age: age(of: item))
                        .tag(item.id)
                        #if os(iOS)
                            .startTodaySwipe(item)
                        #endif
                }
            } header: {
                #if os(iOS)
                    if !shown.isEmpty { Text(Self.subtitle) }
                #endif
            }
        }
        .itemSelectionActions(items: shown) { chosen in
            DoneAndTrashMenu(items: chosen)
        }
        .listDraft(for: .list(.actions), into: $draft)
        .overlay {
            if draft == nil, shown.isEmpty {
                EmptyList("Nothing Unchanged", symbol: Page.actions.symbol, description: "Every action has changed in the last two weeks.")
            }
        }
        .navigationTitle(Page.actions.rawValue)
        #if os(macOS)
            .navigationSubtitle(Self.subtitle)
        #endif
    }

    /// "2 weeks", or "3 months" from nine weeks on.
    private func age(of item: Item) -> String {
        let days = ActionsList.daysUnchanged(item, today: model.today, boundary: model.boundary, in: .current)
        return days < 63 ? "\(days / 7) weeks" : "\(days / 30) months"
    }
}

/// A group's heading: the context, project or area's name, or what the items have none of, with
/// the context's own symbol or the detail's.
private struct ActionsGroupHeading: View {
    let heading: ListGroup.Heading

    var body: some View {
        switch heading {
        case .context(let context):
            GroupHeading(context.name, symbol: context.symbol.isEmpty ? ItemField.contexts.symbol : context.symbol)
        case .project(let project):
            GroupHeading(project.displayTitle, symbol: ItemField.project.symbol)
        case .area(let area):
            GroupHeading(area.displayName, symbol: ItemField.area.symbol)
        case .noContext:
            GroupHeading("Anywhere", symbol: "location")
        case .noProject:
            GroupHeading("Not Under a Task", symbol: ItemField.project.symbol)
        case .noArea:
            GroupHeading("No Area", symbol: ItemField.area.symbol)
        case .all:
            EmptyView()
        }
    }
}

/// How Actions is grouped and filtered: in the View menu on the Mac, and the list's menu on
/// iPhone.
struct ActionsViewOptions: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ActionsGrouping.key) private var grouping = ActionsGrouping.context

    var body: some View {
        @Bindable var model = model
        Picker("Group Actions", selection: $grouping) {
            ForEach(ActionsGrouping.allCases, id: \.self) { grouping in
                Text(grouping.name).tag(grouping)
            }
        }
        .pickerStyle(.inline)
        Section("Filter Actions") {
            Picker("Time Available", selection: $model.actionsFilter.time) {
                Text("Any Time").tag(TimeEstimate?.none)
                ForEach(TimeEstimate.allCases, id: \.self) { time in
                    Text(time.longName).tag(Optional(time))
                }
            }
            Picker("Energy", selection: $model.actionsFilter.energy) {
                Text("Any Energy").tag(Energy?.none)
                ForEach(Energy.allCases, id: \.self) { energy in
                    Text(energy.name).tag(Optional(energy))
                }
            }
            Toggle("Due Within a Week", isOn: $model.actionsFilter.dueSoon)
            Button("Clear Filters") { model.actionsFilter = ActionsFilter() }
                .disabled(model.actionsFilter.isEmpty)
        }
    }
}

extension ActionsGrouping {
    static let key = "actions-grouping"

    var name: String {
        switch self {
        case .context: "By Context"
        case .project: "By Task"
        case .area: "By Area"
        case .none: "All Together"
        }
    }
}

extension ActionsFilter {
    /// The filters in use, in a few words: "up to 15 min · low energy".
    var summary: String {
        var parts: [String] = []
        if let time { parts.append("up to \(time.name)") }
        if let energy { parts.append(energy == .low ? "low energy" : "\(energy.name.lowercased()) energy or less") }
        if dueSoon { parts.append("due within a week") }
        return parts.joined(separator: " · ")
    }
}

extension TimeEstimate {
    /// As a tag: "15 min".
    var name: String {
        switch self {
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .thirtyMinutes: "30 min"
        case .oneHour: "1 hour"
        case .twoHoursOrMore: "2 hours+"
        }
    }

    /// In a menu: "15 Minutes".
    var longName: String {
        switch self {
        case .fiveMinutes: "5 Minutes"
        case .fifteenMinutes: "15 Minutes"
        case .thirtyMinutes: "30 Minutes"
        case .oneHour: "1 Hour"
        case .twoHoursOrMore: "2 Hours or More"
        }
    }
}

extension Energy {
    var name: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

#Preview(traits: .previewRecords) {
    NavigationStack { ActionsView() }
}
