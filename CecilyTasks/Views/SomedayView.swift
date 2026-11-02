import SwiftData
import SwiftUI
import TasksCore

/// Ideas for some day: items and projects, grouped by area. Activate moves an
/// item to Actions and makes a project active.
struct SomedayView: View {
    /// A new item being typed at the top of the list.
    @State private var draft: NewItemDraft?
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "someday" && $0.statusRaw != "dropped" }, animation: .default) private var items: [Item]

    var body: some View {
        @Bindable var model = model
        let groups = SomedayList.groups(items, today: model.today, doneSince: model.dayStart, showsHidden: model.showsHidden)
        let computed = groups.map { ListRow.rows($0.items, doneSince: model.dayStart) { $0.isIn(area: model.area) } }
        let sections = zip(groups, model.settled(computed)).map { ($0, $1) }.filter { !$0.1.isEmpty }
        List(selection: $model.selection) {
            ForEach(sections, id: \.0.id) { group, rows in
                // A section with nothing to head it has no header.
                if model.area == nil {
                    Section {
                        sectionRows(rows, group: group)
                    } header: {
                        GroupHeading(group.area.map { $0.displayName } ?? "No Area", symbol: ItemField.area.symbol)
                    }
                } else {
                    Section {
                        sectionRows(rows, group: group)
                    }
                }
            }
        }
        .itemSelectionActions(items: sections.flatMap { $0.1.map(\.item) }, arrangeable: sections.map(\.1)) { chosen in
            Button("Activate") { model.activate(chosen) }
                .menuKey(KeyCommand.toActions)
            DoneAndTrashMenu(items: chosen)
        }
        .listDraft(for: .list(.someday), into: $draft)
        .overlay {
            if draft == nil, sections.isEmpty {
                EmptyList("Nothing for Someday", symbol: Page.someday.symbol, description: "Ideas for some day appear here.")
            }
        }
        .navigationTitle(Page.someday.rawValue)
    }

    private func sectionRows(_ rows: [ListRow], group: SomedayGroup) -> some View {
        ForEach(rows) { row in
            ItemRow(item: row.item, isSubItem: row.isSubItem, depth: row.depth, nestedUnder: row.under)
                .tag(row.item.id)
                .subItemDragging(row, group: group.dropGroup)
                #if os(iOS)
                    .swipeActions(edge: .leading) {
                        Button("Activate", systemImage: Page.actions.symbol) { model.activate([row.item]) }
                        .tint(.accentColor)
                    }
                #endif
        }
        .dropsBetween(rows, model: model, group: group.dropGroup)
    }
}

#Preview(traits: .previewRecords) {
    NavigationStack { SomedayView() }
}
