import SwiftData
import SwiftUI
import TasksCore

/// Things kept for reference, grouped by area, then by project.
struct ReferenceView: View {
    /// A new item being typed at the top of the list.
    @State private var draft: NewItemDraft?
    @Environment(AppModel.self) private var model
    @Query(
        filter: #Predicate<Item> {
            ($0.bucketRaw == "reference" || ($0.bucketRaw == "action" && $0.kindRaw == "note")) && $0.statusRaw != "dropped"
        }, animation: .default)
    private var items: [Item]

    var body: some View {
        @Bindable var model = model
        let groups = ReferenceList.groups(items, today: model.today, doneSince: model.dayStart, showsHidden: model.showsHidden)
        let computed = groups.map { ListRow.rows($0.items, doneSince: model.dayStart) { $0.isIn(area: model.area) } }
        let shown = zip(groups, model.settled(computed)).map { ($0, $1) }.filter { !$0.1.isEmpty }
        let sections = shown.enumerated().map { index, section in
            (section.0, section.1, index == 0 || shown[index - 1].0.area?.id != section.0.area?.id)
        }
        List(selection: $model.selection) {
            ForEach(sections, id: \.0.id) { group, rows, startsArea in
                let showsArea = startsArea && model.area == nil
                // A section with nothing to head it has no header.
                if showsArea || group.project != nil {
                    Section {
                        sectionRows(rows, group: group)
                    } header: {
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            if showsArea {
                                GroupHeading(group.area.map { $0.displayName } ?? "No Area", symbol: ItemField.area.symbol)
                            }
                            if let project = group.project {
                                GroupHeading(project.displayTitle, symbol: ItemField.project.symbol)
                            }
                        }
                    }
                } else {
                    Section {
                        sectionRows(rows, group: group)
                    }
                }
            }
        }
        .itemSelectionActions(items: sections.flatMap { $0.1.map(\.item) }, arrangeable: sections.map(\.1)) { chosen in
            DoneAndTrashMenu(items: chosen)
        }
        .listDraft(for: .list(.reference), into: $draft)
        .overlay {
            if draft == nil, sections.isEmpty {
                EmptyList("Nothing in Reference", symbol: Page.reference.symbol, description: "Things kept for reference appear here.")
            }
        }
        .navigationTitle(Page.reference.rawValue)
    }

    private func sectionRows(_ rows: [ListRow], group: ReferenceGroup) -> some View {
        ForEach(rows) { row in
            ItemRow(item: row.item, isSubItem: row.isSubItem, depth: row.depth, nestedUnder: row.under)
                .tag(row.item.id)
                .subItemDragging(row, group: group.dropGroup)
        }
        .dropsBetween(rows, model: model, group: group.dropGroup)
    }
}

#Preview(traits: .previewRecords) {
    NavigationStack { ReferenceView() }
}
