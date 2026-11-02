import SwiftData
import SwiftUI
import TasksCore

/// Everything captured and not yet decided, by when it came in (Today,
/// Yesterday, This Week, Earlier), each in its order, with what's been done today struck through. The selected rows, or the one clicked, can be filed from the context menu, and a row
/// with a swipe on iPhone and iPad.
struct InboxView: View {
    /// A new item being typed at the top of the list.
    @State private var draft: NewItemDraft?
    @Environment(AppModel.self) private var model
    @Query(
        filter: #Predicate<Item> { $0.bucketRaw == "inbox" && $0.statusRaw != "dropped" }, sort: \Item.createdAt, order: .reverse,
        animation: .default)
    private var inbox: [Item]
    /// When the Inbox last had nothing left to decide, kept on this device.
    @AppStorage("inbox-emptied") private var emptiedAt: Double = 0

    /// The Inbox's rows: those at the top in the area the lists are narrowed to, with what's
    /// nested under them.
    private var rows: [ListRow] {
        ListRow.rows(inbox.filter(isShown).sorted(by: Item.inListOrder), doneSince: model.dayStart) { $0.isIn(area: model.area) }
    }

    /// Open or done today, not hidden until a later day, and not under a task that's gone.
    private func isShown(_ item: Item) -> Bool {
        item.isListed(today: model.today, doneSince: model.dayStart, showsHidden: model.showsHidden)
    }

    /// How many open items there are to decide in the whole Inbox, whatever the area.
    private var openCount: Int { inbox.count { $0.status == .open && isShown($0) } }

    var body: some View {
        let rows = self.rows
        list(rows)
            .navigationTitle(Page.inbox.rawValue)
            .onChange(of: openCount) { before, now in
                if before > 0, now == 0 { emptiedAt = Date.now.timeIntervalSince1970 }
            }
    }

    private func list(_ rows: [ListRow]) -> some View {
        @Bindable var model = model
        return List(selection: $model.selection) {
            ForEach(groups(rows), id: \.period) { period, rows in
                Section(period.name) {
                    ForEach(rows) { row(for: $0, in: period) }
                        .dropsBetween(rows, model: model, group: Self.dropGroup(period))
                }
            }
        }
        .itemSelectionActions(items: groups(rows).flatMap { $0.rows.map(\.item) }, arrangeable: groups(rows).map(\.rows)) { chosen in
            menu(for: chosen)
        }
        .listDraft(for: .list(.inbox), into: $draft)
        .overlay {
            if draft == nil, !inbox.contains(where: isShown) {
                EmptyList("Nothing to Decide", symbol: Page.inbox.symbol, description: emptiedDescription) {
                    Button("New Item") { model.newItem() }
                    Button("Brain Dump") { model.isBrainDumping = true }
                }
            } else if draft == nil, rows.isEmpty {
                EmptyList("Nothing in This Area", symbol: Page.inbox.symbol, description: "Show all areas to see the rest of the Inbox.")
            }
        }
    }

    /// When the Inbox was last emptied, or what it's for when it never has been.
    private var emptiedDescription: String {
        guard emptiedAt > 0 else { return "Everything you add goes here until you've decided what it is." }
        return InboxList.emptied(at: Date(timeIntervalSince1970: emptiedAt), now: .now, boundary: model.boundary, in: .current) + "."
    }

    /// The rows by when the row at the top of each came in, in the order of `InboxList.Period`.
    private func groups(_ rows: [ListRow]) -> [(period: InboxList.Period, rows: [ListRow])] {
        var grouped: [InboxList.Period: [ListRow]] = [:]
        var period: InboxList.Period?
        for row in rows {
            if !row.isSubItem {
                period = InboxList.period(of: row.item, today: model.today, boundary: model.boundary, in: .current)
            }
            if let period { grouped[period, default: []].append(row) }
        }
        let periods = InboxList.Period.allCases.compactMap { period in grouped[period].map { (period, $0) } }
        return zip(periods, model.settled(periods.map(\.1))).map { ($0.0, $1) }.filter { !$0.1.isEmpty }
    }

    /// The rows that came in during `period`, which rows from another day can't be moved into.
    private static func dropGroup(_ period: InboxList.Period) -> DropGroup {
        DropGroup(id: "inbox-\(period)", headings: [])
    }

    private func row(for row: ListRow, in period: InboxList.Period) -> some View {
        let item = row.item
        return ItemRow(item: item, isSubItem: row.isSubItem, depth: row.depth, nestedUnder: row.under)
            .tag(item.id)
            .subItemDragging(row, group: Self.dropGroup(period))
            #if os(iOS)
                .swipeActions(edge: .leading) {
                    if !row.isSubItem {
                        Button("Action", systemImage: "checklist") { quickFile(item, .action) }
                        .tint(.accentColor)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Trash", systemImage: "trash", role: .destructive) { quickFile(item, .trash) }
                    if !row.isSubItem {
                        Button("Someday", systemImage: "moon.zzz") { quickFile(item, .someday) }
                        .tint(.purple)
                        Button("Reference", systemImage: "books.vertical") { quickFile(item, .reference) }
                        .tint(.brown)
                        Button("Waiting", systemImage: "hourglass") { quickFile(item, .waiting(person: "", followUp: nil)) }
                        .tint(.cyan)
                        Button("Schedule for Today", systemImage: "calendar") { model.startToday([item]) }
                        .tint(.teal)
                    }
                }
            #endif
    }

    private func quickFile(_ item: Item, _ destination: ClarifyOutcome.Destination) {
        model.file(item, ClarifyOutcome(destination))
    }

    @ViewBuilder private func menu(for items: [Item]) -> some View {
        Button("Action") { model.file(items, ClarifyOutcome(.action)) }
            .menuKey(KeyCommand.toActions)
        Button("Waiting…") { model.perform(.move(.waiting), items) }
            .menuKey(KeyCommand.toWaiting)
        Button("Someday") { model.file(items, ClarifyOutcome(.someday)) }
            .menuKey(KeyCommand.toSomeday)
        Button("Reference") { model.file(items, ClarifyOutcome(.reference)) }
            .menuKey(KeyCommand.toReference)
        Divider()
        Button("Move to Trash", role: .destructive) { model.file(items, ClarifyOutcome(.trash)) }
            .menuKey(KeyCommand.trash)
    }
}

#Preview(traits: .previewRecords) {
    NavigationStack { InboxView() }
}
