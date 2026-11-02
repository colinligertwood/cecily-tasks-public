import SwiftData
import SwiftUI
import TasksCore

/// What the search field finds: items whose titles, notes or attachments'
/// names have its words, grouped by list, in the area chosen and narrowed by the filter menu.
/// Rows are the lists' own, with the notes where they match.
struct SearchResults: View {
    @Environment(AppModel.self) private var model
    @Query private var items: [Item]

    var body: some View {
        @Bindable var model = model
        let groups = ItemSearch.results(items, query: model.searchText, filter: model.searchFilter) { $0.isIn(area: model.area) }
        List(selection: $model.selection) {
            ForEach(groups) { group in
                Section(group.bucket.listName) {
                    ForEach(group.results) { result in
                        ItemRow(item: result.item, excerpt: result.excerpt)
                            .tag(result.item.id)
                    }
                }
            }
        }
        .itemSelectionActions(items: groups.flatMap { $0.results.map(\.item) }) { chosen in
            DoneAndTrashMenu(items: chosen)
        }
        .overlay {
            if groups.isEmpty {
                if model.isSearchEmpty {
                    EmptyList("Search", symbol: "magnifyingglass", description: "Find anything by the words in its title, notes, or attachments.")
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SearchFilterMenu()
                }
            }
        #endif
        .navigationTitle("Search")
    }
}

/// What search is narrowed to beyond its words: open or done, a context, and attachments.
struct SearchFilterMenu: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Context.sortOrder) private var contexts: [Context]

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Open or Done", selection: $model.searchFilter.status) {
                Text("Open and Done").tag(ItemSearch.Filter.Status.any)
                Text("Open").tag(ItemSearch.Filter.Status.open)
                Text("Done").tag(ItemSearch.Filter.Status.done)
            }
            .pickerStyle(.inline)
            Picker("Context", selection: $model.searchFilter.context) {
                Text("Any Context").tag(UUID?.none)
                ForEach(contexts.filter { !$0.isHidden || $0.id == model.searchFilter.context }) { context in
                    Label(context.name, systemImage: context.symbol.isEmpty ? ItemField.contexts.symbol : context.symbol)
                        .tag(Optional(context.id))
                }
            }
            .pickerStyle(.inline)
            Toggle("Has Attachments", isOn: $model.searchFilter.hasAttachments)
            if model.searchFilter.isOn {
                Divider()
                Button("Show Everything") { model.searchFilter = ItemSearch.Filter() }
            }
        } label: {
            Label("Filter", systemImage: model.searchFilter.isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(model.searchFilter.isOn ? "Search is narrowed" : "Narrow the search")
    }
}

/// The last searches, kept on the device.
private struct RecentSearchStorage: DynamicProperty {
    @AppStorage("recent-searches") private var text = ""

    var list: [String] { text.split(separator: "\n").map(String.init) }

    func remember(_ query: String) {
        text = RecentSearches.adding(query, to: list).joined(separator: "\n")
    }
}

#if os(macOS)
    /// The search control in the Mac's toolbar: a magnifying glass, which opens into the system's
    /// search field when it's clicked or with Edit ▸ Search (⌘F). The field goes back to the
    /// magnifying glass when it loses the cursor while empty, or with Escape, which also clears
    /// it. Its menu has the last searches. A search is remembered when it's submitted or an
    /// item it found is opened.
    struct ToolbarSearch: View {
        @Environment(AppModel.self) private var model
        @AppStorage(KeyHints.key) private var showsKeyHints = true
        private let recent = RecentSearchStorage()

        /// Whether the field shows: while it has the cursor, or words.
        private var isOpen: Bool { model.isSearching || !model.searchText.isEmpty }

        var body: some View {
            @Bindable var model = model
            HStack(spacing: 0) {
                Button("Search", systemImage: "magnifyingglass") { model.isSearching = true }
                    .labelStyle(.iconOnly)
                    .help(showsKeyHints ? "Search (⌘F)" : "Search")
                    .frame(width: isOpen ? 0 : nil)
                    .opacity(isOpen ? 0 : 1)
                    .disabled(isOpen)
                    .accessibilityHidden(isOpen)
                SystemSearchField(
                    text: $model.searchText, isEditing: $model.isSearching, isShown: isOpen, recent: recent.list, onSubmit: remember
                )
                .frame(width: isOpen ? 180 : 0)
                .opacity(isOpen ? 1 : 0)
            }
            .onChange(of: model.openItem) { _, id in
                if id != nil { remember() }
            }
        }

        private func remember() {
            guard !model.isSearchEmpty else { return }
            recent.remember(model.searchText)
        }
    }

    /// The system's search field: `text` as it's typed, and `isEditing` while it has the cursor,
    /// which it takes when `isEditing` is set. Return calls `onSubmit`; Escape empties it and
    /// gives up the cursor. Its menu lists `recent`. Tab passes it by while it isn't `isShown`.
    private struct SystemSearchField: NSViewRepresentable {
        @Binding var text: String
        @Binding var isEditing: Bool
        let isShown: Bool
        let recent: [String]
        let onSubmit: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: NSViewRepresentableContext<Self>) -> NSSearchField {
            let field = NSSearchField()
            field.placeholderString = "Search"
            field.sendsSearchStringImmediately = true
            field.delegate = context.coordinator
            field.target = context.coordinator
            field.action = #selector(Coordinator.changed(_:))
            field.searchMenuTemplate = Self.recentsMenu
            return field
        }

        func updateNSView(_ field: NSSearchField, context: NSViewRepresentableContext<Self>) {
            context.coordinator.parent = self
            if field.stringValue != text { field.stringValue = text }
            if field.recentSearches != recent { field.recentSearches = recent }
            field.refusesFirstResponder = !isShown
            if isEditing, field.currentEditor() == nil, let window = field.window {
                window.makeFirstResponder(field)
            }
        }

        /// The field's menu: the last searches, or a line saying there are none.
        private static var recentsMenu: NSMenu {
            let menu = NSMenu(title: "Recent Searches")
            let title = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
            title.tag = NSSearchField.recentsTitleMenuItemTag
            let recents = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            recents.tag = NSSearchField.recentsMenuItemTag
            let none = NSMenuItem(title: "No Recent Searches", action: nil, keyEquivalent: "")
            none.tag = NSSearchField.noRecentsMenuItemTag
            menu.items = [title, recents, none]
            return menu
        }

        final class Coordinator: NSObject, NSSearchFieldDelegate {
            var parent: SystemSearchField

            init(_ parent: SystemSearchField) {
                self.parent = parent
            }

            /// The clear button, and a recent search chosen from the menu.
            @objc func changed(_ field: NSSearchField) {
                if parent.text != field.stringValue { parent.text = field.stringValue }
            }

            func controlTextDidBeginEditing(_ notification: Notification) {
                if !parent.isEditing { parent.isEditing = true }
            }

            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSSearchField else { return }
                parent.text = field.stringValue
            }

            func controlTextDidEndEditing(_ notification: Notification) {
                if parent.isEditing { parent.isEditing = false }
            }

            func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
                switch selector {
                case #selector(NSResponder.insertNewline(_:)):
                    parent.onSubmit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.text = ""
                    control.window?.makeFirstResponder(nil)
                    return true
                default:
                    return false
                }
            }
        }
    }
#else
    /// The search field at the top of the Search tab, with the last searches suggested while it's
    /// empty. A search is remembered when it's submitted or an item it found is opened.
    private struct SearchField: ViewModifier {
        @Environment(AppModel.self) private var model
        private let recent = RecentSearchStorage()

        func body(content: Content) -> some View {
            @Bindable var model = model
            content
                .searchable(text: $model.searchText, isPresented: $model.isSearching, prompt: "Search")
                .searchSuggestions {
                    if model.searchText.isEmpty {
                        ForEach(recent.list, id: \.self) { query in
                            Label(query, systemImage: "clock.arrow.circlepath")
                                .searchCompletion(query)
                        }
                    }
                }
                .onSubmit(of: .search) { remember() }
                .onChange(of: model.openItem) { _, id in
                    if id != nil { remember() }
                }
        }

        private func remember() {
            guard !model.isSearchEmpty else { return }
            recent.remember(model.searchText)
        }
    }

    extension View {
        func searchField() -> some View {
            modifier(SearchField())
        }
    }
#endif

#Preview(traits: .previewRecords) {
    NavigationStack { SearchResults() }
}
