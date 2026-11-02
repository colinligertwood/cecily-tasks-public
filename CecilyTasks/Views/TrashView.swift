import SwiftData
import SwiftUI
import TasksCore

/// What's been moved to the Trash, most recently trashed first, with each
/// task's subtasks under it. Put Back returns an item to the list it came from; Empty Trash
/// deletes everything in it, after asking: on the Mac from the strip above the list
/// (`ListStrip`), and on iPhone and iPad from the list's title menu. Each item is deleted 30 days after it was trashed.
struct TrashView: View {
    @Environment(AppModel.self) private var model
    @Query private var items: [Item]

    var body: some View {
        @Bindable var model = model
        let rows = ListRow.rows(TrashList.items(items), doneSince: nil)
        List(selection: $model.selection) {
            ForEach(rows) { row in
                ItemRow(item: row.item, isSubItem: row.isSubItem, depth: row.depth, nestedUnder: row.under)
                    .tag(row.item.id)
                    #if os(iOS)
                        .swipeActions(edge: .leading) {
                            if row.item.bucket == .trash {
                                Button("Put Back", systemImage: "arrow.uturn.backward") { model.putBack([row.item]) }
                                .tint(.accentColor)
                            }
                        }
                    #endif
            }
        }
        .itemSelectionActions(items: rows.map(\.item)) { chosen in
            let trashed = chosen.filter { $0.bucket == .trash }
            if let item = trashed.first {
                Button(trashed.count == 1 ? "Put Back in \(TrashList.destination(of: item).listName)" : "Put Back") { model.putBack(trashed) }
            }
        }
        .overlay {
            if rows.isEmpty {
                EmptyList("Nothing in the Trash", symbol: Page.trash.symbol, description: "What you move to the Trash stays here for 30 days.")
            }
        }
        .confirmationDialog("Empty the Trash?", isPresented: Bindable(model).isEmptyingTrash) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
        } message: {
            Text("Everything in it will be deleted. This can't be undone.")
        }
        .navigationTitle(Page.trash.rawValue)
    }
}

#Preview(traits: .previewRecords) {
    NavigationStack { TrashView() }
}
