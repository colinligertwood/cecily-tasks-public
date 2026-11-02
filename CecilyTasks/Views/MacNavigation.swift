import SwiftData
import SwiftUI
import TasksCore

#if os(macOS)
    /// Whether the Mac's sidebar is hidden, set from the View menu.
    enum SidebarHidden {
        static let key = "sidebar-hidden"
    }

    struct MacNavigation: View {
        let inboxCount: Int
        @Environment(AppModel.self) private var model
        @AppStorage(SidebarHidden.key) private var sidebarHidden = false
        @AppStorage(KeyHints.key) private var showsKeyHints = true
        @Query private var reviews: [ReviewRecord]

        /// The sidebar's narrowest width, which it opens at: room for a row with everything in it,
        /// so a list's name and its key always show. The list's insets and the selection's padding,
        /// a small symbol or the review's tick and the gap after it, the longest list name and a
        /// key after it, the gap before the right, and the Inbox's count. It depends only on the
        /// system's fonts.
        static var sidebarWidth: CGFloat {
            let body = NSFont.preferredFont(forTextStyle: .body)
            let names = Page.allCases.map { ($0.rawValue as NSString).size(withAttributes: [.font: body]).width }.max() ?? 0
            let insets: CGFloat = 2 * 10 + 2 * 8
            let symbol: CGFloat = 24 + 6
            let gap: CGFloat = 8
            let key: CGFloat = 26 + 6
            let count: CGFloat = 32
            return (insets + symbol + names + gap + key + count).rounded(.up)
        }

        /// The window's shortest height: the toolbar and every sidebar row, and the review's
        /// progress when it shows.
        static func minimumHeight(isReviewing: Bool) -> CGFloat {
            let row: CGFloat = 24 + 8
            let divider: CGFloat = 12
            let toolbar: CGFloat = 52
            let foot = isReviewing ? row + 24 : 0
            return (toolbar + CGFloat(Page.allCases.count) * row + 2 * divider + foot).rounded(.up)
        }

        /// A list's row with a small symbol beside its name, as the Mac's own sidebars have, or in
        /// the weekly review, for a list to review, whether it's been reviewed; its key after its
        /// name, and its count at the right.
        private func row(_ page: Page, count: Int = 0) -> some View {
            Label {
                // The key after the name, as the inspector has a detail's, lighter.
                HStack(spacing: Spacing.small) {
                    Text(page.rawValue)
                    if showsKeyHints, let key = KeyCommand.lists.first(where: { $0.page == page })?.chord.map(KeyCommand.label) {
                        Text(key)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            } icon: {
                // In the weekly review, a list to review has its tick in place of its symbol, at
                // the same size, so nothing moves.
                if model.isReviewing, let list = page.reviewList {
                    ReviewMark(isReviewed: WeeklyReview.ticked(reviews).contains(list), isOnSymbol: false)
                } else {
                    Image(systemName: page.symbol)
                }
            }
            .lineLimit(1)
            .badge(count)
        }

        var body: some View {
            @Bindable var model = model
            NavigationSplitView(columnVisibility: Binding(get: { sidebarHidden ? .detailOnly : .all }, set: { sidebarHidden = $0 == .detailOnly })) {
                List(
                    selection: Binding<Page?>(
                        get: { model.page },
                        set: { page in
                            guard let page else { return }
                            model.page = page
                            model.selection = []
                            model.openItem = nil
                            model.openEvent = nil
                            model.searchText = ""
                            model.isSearching = false
                        })
                ) {
                    row(.agenda)
                        .tag(Page.agenda)
                        .dropDestination(for: String.self) { payloads, _ in model.start(dragged: payloads, on: model.today) }
                    row(.inbox, count: inboxCount)
                        .tag(Page.inbox)
                    Divider()
                    ForEach([Page.actions, .waiting, .someday, .reference]) { page in
                        row(page)
                    }
                    Divider()
                    row(.trash)
                        .tag(Page.trash)
                }
                .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: Self.sidebarWidth + 120)
                .scrollDisabled(true)
                .safeAreaInset(edge: .bottom) {
                    if model.isReviewing {
                        ReviewProgress(ticked: WeeklyReview.ticked(reviews).count)
                            .padding(12)
                    }
                }
            } detail: {
                Group {
                    if model.isSearchEmpty {
                        VStack(spacing: 0) {
                            ListStrip()
                            model.page.view
                        }
                    } else {
                        SearchResults()
                    }
                }
                .frame(minWidth: ItemRow.minimumWidth)
                .overlay {
                    if let id = model.openItem {
                        ItemCard(itemID: id)
                    } else if let event = model.openEvent {
                        EventCard(event: event)
                    }
                }
                .inspector(isPresented: $model.showsInspector) {
                    SelectionInspector()
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
                }
            }
            .frame(minHeight: Self.minimumHeight(isReviewing: model.isReviewing))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack {
                        AreaFilter()
                        ToolbarSearch()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.isReviewing, let list = model.page.reviewList, !WeeklyReview.ticked(reviews).contains(list) {
                        Button("Reviewed", systemImage: "checkmark.circle") { model.markReviewed(model.page) }
                            .labelStyle(.titleAndIcon)
                            .help("Mark \(model.page.rawValue) as reviewed and go to the next list")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !model.isSearchEmpty {
                        SearchFilterMenu()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Inspector", systemImage: "sidebar.trailing") { model.showsInspector.toggle() }
                        .help(model.showsInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
                }
            }
        }
    }

    /// A strip above the list showing, with its own button at the right: New and the kind of
    /// thing the list holds, or Empty Trash… in the Trash.
    private struct ListStrip: View {
        @Environment(AppModel.self) private var model
        @AppStorage(KeyHints.key) private var showsKeyHints = true
        @Query(filter: #Predicate<Item> { $0.bucketRaw == "trash" }) private var trashed: [Item]

        var body: some View {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    if model.page == .trash {
                        Button("Empty Trash…", role: .destructive) { model.isEmptyingTrash = true }
                            .disabled(trashed.isEmpty)
                    } else {
                        let title = model.page.newTitle
                        Button(title) { model.newItem(in: model.page) }
                            .help(showsKeyHints ? "\(title) (⌘N)" : title)
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    extension Page {
        /// What New makes in the list: the kind of thing it holds.
        var newTitle: String {
            switch self {
            case .agenda, .actions: "New Action"
            case .inbox: "New Item"
            case .waiting: "New Waiting Item"
            case .someday: "New Idea"
            case .reference: "New Reference"
            case .trash: "New Item"
            }
        }
    }
#endif
