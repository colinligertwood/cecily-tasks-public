import SwiftData
import SwiftUI
import TasksCore

/// What other people are doing: grouped by who it's waiting for, soonest
/// follow-up first, below an alphabet that narrows it to the people under one letter. Each can be
/// received, nudged with a follow-up action, or taken back. Its order is the follow-ups', so rows
/// can't be put in order by hand, only dropped on another to go under it.
struct WaitingView: View {
    /// A new item being typed at the top of the list.
    @State private var draft: NewItemDraft?
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "waiting" && $0.statusRaw != "dropped" }, animation: .default) private var waiting: [Item]

    var body: some View {
        @Bindable var model = model
        let groups = WaitingList.groups(waiting, today: model.today, doneSince: model.dayStart, showsHidden: model.showsHidden)
        let computed = groups.map { ListRow.rows($0.items, doneSince: model.dayStart) { $0.isIn(area: model.area) } }
        let everyone = zip(groups, model.settled(computed)).map { ($0, $1) }.filter { !$0.1.isEmpty }
        let all = everyone.map(\.0)
        let chosen = everyone.filter { $0.0.tab == model.waitingTab }
        let sections = chosen.isEmpty ? everyone : chosen
        VStack(spacing: 0) {
            if !all.isEmpty {
                Divider()
                WaitingIndex(groups: all, chosen: $model.waitingTab)
                Divider()
            }
            List(selection: $model.selection) {
                ForEach(sections, id: \.0.id) { group, rows in
                    Section {
                        ForEach(rows) { row in
                            ItemRow(item: row.item, isSubItem: row.isSubItem, depth: row.depth, nestedUnder: row.under)
                                .tag(row.item.id)
                                .subItemDragging(row)
                                #if os(iOS)
                                    .swipeActions(edge: .leading) {
                                        if !row.isSubItem {
                                            Button(row.item.status == .done ? "Not Received" : "Received", systemImage: "tray.and.arrow.down") {
                                                model.toggleDone([row.item])
                                            }
                                            .tint(.accentColor)
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        if !row.isSubItem {
                                            Button("Nudge", systemImage: "phone.arrow.up.right") { model.nudge([row.item]) }
                                            .tint(.orange)
                                            Button("Take Back", systemImage: "arrow.uturn.left") { model.takeBack([row.item]) }
                                            .tint(.indigo)
                                        }
                                    }
                                #endif
                        }
                    } header: {
                        GroupHeading(group.name, symbol: ItemField.waitingFor.symbol)
                    }
                }
            }
            .itemSelectionActions(items: sections.flatMap { $0.1.map(\.item) }, arrangeable: sections.map(\.1), reorders: false) { chosen in
                Button(chosen.allSatisfy { $0.status == .done } ? "Not Received" : "Received") { model.toggleDone(chosen) }
                    .menuKey(KeyCommand.done)
                Button("Nudge") { model.nudge(chosen) }
                Button("Take Back") { model.takeBack(chosen) }
                    .menuKey(KeyCommand.toActions)
                Divider()
                Button("Move to Trash", role: .destructive) { model.file(chosen, ClarifyOutcome(.trash)) }
                    .menuKey(KeyCommand.trash)
            }
            .listDraft(for: .list(.waiting), into: $draft)
            .overlay {
                if draft == nil, sections.isEmpty {
                    EmptyList("Nothing Waiting", symbol: Page.waiting.symbol, description: "Things someone else is doing appear here.")
                }
            }
        }
        .navigationTitle(Page.waiting.rawValue)
    }
}

extension WaitingGroup {
    fileprivate var name: String { person ?? "No One Named" }
}

/// Waiting's alphabet, like an index card box's tabs: A to Z, then # and No One when there are
/// people filed under them, with a dot under the letters that have someone. The letters share the
/// width, up to a size, so the row never scrolls. Choosing one narrows the list to the people under
/// it; choosing it again shows everyone.
private struct WaitingIndex: View {
    let groups: [WaitingGroup]
    @Binding var chosen: WaitingTab?
    @State private var width: CGFloat = 0

    private static let widestLetter: CGFloat = 28
    private static let noOneWidth: CGFloat = 72
    private static let margin: CGFloat = 16

    var body: some View {
        let tabs = WaitingTab.tabs(for: groups)
        let used = Set(groups.map(\.tab))
        let letterWidth = letterWidth(tabs)
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                let isChosen = chosen == tab
                Button {
                    chosen = isChosen ? nil : tab
                } label: {
                    VStack(spacing: Spacing.hairline) {
                        Text(label(tab))
                            .font(letterWidth < 20 ? .caption : .body)
                            .frame(height: Spacing.indexChipHeight)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(isChosen ? Color.white : used.contains(tab) ? Color.primary : Color.secondary)
                            .background {
                                if isChosen {
                                    Capsule().fill(Color.accentColor).frame(minWidth: min(letterWidth, Spacing.indexChipHeight))
                                }
                            }
                        Circle()
                            .fill(used.contains(tab) ? Color.secondary : Color.clear)
                            .frame(width: Spacing.indexDot, height: Spacing.indexDot)
                    }
                    .frame(width: tab == .noOne ? Self.noOneWidth : letterWidth)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!used.contains(tab))
                .accessibilityLabel(tab == .letter("#") ? "Other" : label(tab))
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }

    /// The letters' share of the width beside No One, no wider than `widestLetter`.
    private func letterWidth(_ tabs: [WaitingTab]) -> CGFloat {
        let letters = tabs.filter { $0 != .noOne }.count
        let room = width - 2 * Self.margin - (tabs.contains(.noOne) ? Self.noOneWidth : 0)
        return width > 0 ? min(Self.widestLetter, room / CGFloat(letters)) : Self.widestLetter
    }

    private func label(_ tab: WaitingTab) -> String {
        switch tab {
        case .letter(let letter): letter
        case .noOne: "No One"
        }
    }
}

#Preview(traits: .previewRecords) {
    NavigationStack { WaitingView() }
}
