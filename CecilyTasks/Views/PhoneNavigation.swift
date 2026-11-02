import SwiftData
import SwiftUI
import TasksCore

#if os(iOS)
    /// The ID of the project open on iPhone, for its sheet.
    private struct OpenProject: Identifiable {
        let id: UUID
    }

    /// A tab on iPhone: a list's, or Search.
    private enum PhoneTab: Hashable {
        case list(Page)
        case search
    }

    struct PhoneNavigation: View {
        let inboxCount: Int
        @Environment(AppModel.self) private var model
        @State private var showsReview = false
        @State private var showsSearch = false

        var body: some View {
            if model.isReviewing {
                tabs.tabViewBottomAccessory {
                    ReviewBar { showsReview = true }
                }
            } else {
                tabs
            }
        }

        /// The tab showing: Search, or a list's, with More for the lists in it.
        private var tab: Binding<PhoneTab> {
            Binding(
                get: { showsSearch ? .search : .list(model.page == .reference || model.page == .trash ? .someday : model.page) },
                set: { tab in
                    switch tab {
                    case .search:
                        showsSearch = true
                    case .list(let page):
                        showsSearch = false
                        model.page = page
                        model.morePage = nil
                    }
                })
        }

        private var tabs: some View {
            @Bindable var model = model
            return TabView(selection: tab) {
                Tab(Page.agenda.rawValue, systemImage: Page.agenda.symbol, value: PhoneTab.list(.agenda)) { stack(Page.agenda) }
                Tab(Page.inbox.rawValue, systemImage: Page.inbox.symbol, value: PhoneTab.list(.inbox)) { stack(Page.inbox) }
                    .badge(inboxCount)
                Tab(Page.actions.rawValue, systemImage: Page.actions.symbol, value: PhoneTab.list(.actions)) { stack(Page.actions) }
                Tab(Page.waiting.rawValue, systemImage: Page.waiting.symbol, value: PhoneTab.list(.waiting)) { stack(Page.waiting) }
                Tab("More", systemImage: "ellipsis", value: PhoneTab.list(.someday)) { stack(nil) }
                Tab(value: PhoneTab.search, role: .search) {
                    NavigationStack { SearchResults() }
                        .searchField()
                }
            }
            .onChange(of: model.page) { showsSearch = false }
            .sheet(isPresented: $showsReview) { ReviewSheet() }
            .sheet(item: openProject) { OpenItemSheet(itemID: $0.id) }
            .sheet(item: $model.openEvent) { EventSheet(event: $0) }
            .sheet(item: $model.settingsSheet) { pane in
                NavigationStack {
                    Group {
                        if pane == .contexts { ContextsSettings() } else { AreasSettings() }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.settingsSheet = nil }
                        }
                    }
                }
            }
        }

        /// The project open over the tabs.
        private var openProject: Binding<OpenProject?> {
            Binding(get: { model.openItem.map(OpenProject.init) }, set: { model.openItem = $0?.id })
        }

        /// A tab's page, or More's list for nil, with the + button that's on every screen.
        private func stack(_ page: Page?) -> some View {
            NavigationStack {
                if let page { page.view } else { MoreList() }
            }
            .overlay(alignment: .bottomTrailing) { addButton }
        }

        private var addButton: some View {
            Button {
                model.isCapturing = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glassProminent)
            .clipShape(.circle)
            .accessibilityLabel("Add to Inbox")
            .padding(.trailing, 20)
            .padding(.bottom, 16)
        }
    }

    /// A task opened on iPhone, in a sheet: its title, details, subtasks, attachments and notes,
    /// with Done to close it and a menu to add attachments.
    private struct OpenItemSheet: View {
        @Environment(AppModel.self) private var model
        @Query private var found: [Item]

        init(itemID: UUID) {
            _found = Query(filter: #Predicate<Item> { $0.id == itemID })
        }

        var body: some View {
            NavigationStack {
                Group {
                    if let item = found.first {
                        OpenTaskContent(item: item)
                            .padding(.horizontal)
                    } else {
                        ItemNotFound()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.openItem = nil }
                    }
                    if let item = found.first, item.bucket != .trash {
                        ToolbarItem(placement: .secondaryAction) {
                            Menu("Attach", systemImage: "paperclip") { AttachmentMenuItems(item: item) }
                        }
                    }
                }
            }
            .attachmentPanels(inOpenItem: true)
        }
    }

    private struct MoreList: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            @Bindable var model = model
            List {
                ForEach([Page.someday, .reference, .trash]) { page in
                    Button {
                        model.morePage = page
                    } label: {
                        HStack {
                            Label(page.rawValue, systemImage: page.symbol)
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                if !model.isReviewing {
                    Section {
                        Button("Start Review", systemImage: "checklist.checked") { model.startReview() }
                    }
                }
            }
            .navigationTitle("More")
            .navigationDestination(item: $model.morePage) { page in
                page.view
            }
        }
    }
#endif
