import CecilyKit
import SwiftData
import SwiftUI
import TasksCore
import UserNotifications

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@main
struct CecilyTasksApp: App {
    #if os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
        @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var stores = Stores()

    init() {
        #if DEBUG
            if DebugCloudKitSchema.requested {
                Task { @MainActor in
                    await DebugCloudKitSchema.run()
                    exit(0)
                }
            }
        #endif
    }

    var body: some Scene {
        #if os(macOS)
            Window("Cecily Tasks", id: MainWindow.id) {
                content
            }
            .defaultSize(width: 1280, height: 820)
            .defaultLaunchBehavior(.presented)
            .commands {
                AboutCommands(.tasks)
                if case .success(let opened) = stores.current {
                    AppCommands(model: opened.model)
                }
            }
        #else
            WindowGroup {
                content
            }
            .commands {
                if case .success(let opened) = stores.current {
                    AppCommands(model: opened.model)
                }
            }
        #endif
        #if os(macOS)
            Settings {
                if case .success(let opened) = stores.current {
                    SettingsView()
                        .environment(opened.model)
                        .environment(opened.model.cloudSync)
                        .modelContainer(opened.model.container)
                        .id(ObjectIdentifier(opened.model))
                        .frame(width: 480, height: 520)
                }
            }
        #endif
    }

    /// The lists, or why the store couldn't be opened.
    @ViewBuilder private var content: some View {
        switch stores.current {
        case .success(let opened):
            RootView()
                .environment(opened.model)
                .environment(opened.model.cloudSync)
                .modelContainer(opened.model.container)
                .id(OpenedStore(model: ObjectIdentifier(opened.model), outsideRevision: opened.model.outsideRevision))
                .task {
                    opened.model.cloudSync.start()
                    opened.model.updateNotifications()
                }
        case .failure(let error):
            EmptyList("Couldn't Open Your Tasks", symbol: "exclamationmark.triangle", description: error.localizedDescription)
        }
    }
}

#if os(macOS)
    /// The Mac app's one window, without tabs. It opens when the app starts; closing it leaves the
    /// app running, for the menu-bar icon, and the Dock icon, the Window menu, quick entry and a
    /// notification open it again.
    enum MainWindow {
        static let id = "main"

        /// Opens the window, or brings it to the front, and the app with it, the way clicking the
        /// app in the Dock does (`AppDelegate.applicationShouldHandleReopen`).
        @MainActor static func open() {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
#endif

/// The store a window shows, and how many times the Share Sheet has added to it since, so the
/// window reads it afresh after either changes.
private struct OpenedStore: Hashable {
    let model: ObjectIdentifier
    let outsideRevision: Int
}

/// The menu bar's commands: new item, the brain dump and the weekly review, with their shortcuts.
struct AppCommands: Commands {
    let model: AppModel
    #if os(macOS)
        @AppStorage(KeyHints.key) private var showsKeyHints = true
        @AppStorage(SidebarHidden.key) private var sidebarHidden = false
    #endif

    var body: some Commands {
        #if os(macOS)
            CommandGroup(replacing: .sidebar) {
                ForEach(KeyCommand.lists) { command in
                    if let page = command.page {
                        Button(page.rawValue) { model.go(to: page) }
                            .keyboardShortcut(command)
                    }
                }
                Divider()
                Button(sidebarHidden ? "Show Sidebar" : "Hide Sidebar") { sidebarHidden.toggle() }
                    .keyboardShortcut(KeyCommand.sidebar)
                Toggle("Show Keyboard Shortcuts", isOn: $showsKeyHints)
                Divider()
                Button("Open Item") { model.openItem = model.selection.first }
                    .disabled(model.selection.count != 1)
                Button(model.showsInspector ? "Hide Inspector" : "Show Inspector") { model.showsInspector.toggle() }
                    .keyboardShortcut(KeyCommand.inspector)
                Button("Back") { model.back() }
                    .keyboardShortcut(KeyCommand.back)
                    .disabled(model.openItem == nil)
                Toggle("Show Hidden", isOn: Bindable(model).showsHidden)
                Divider()
                Menu("Area") {
                    areaToggle("All Areas", nil)
                        .keyboardShortcut(KeyCommand.allAreas)
                    Divider()
                    ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
                        if index < 9 {
                            areaToggle(area.displayName, area.id).keyboardShortcut(KeyCommand.area(index + 1))
                        } else {
                            areaToggle(area.displayName, area.id)
                        }
                    }
                }
                Menu("Actions") {
                    ActionsViewOptions()
                        .environment(model)
                }
                .disabled(model.page != .actions)
            }
        #endif
        CommandGroup(replacing: .newItem) {
            Button("New Item") {
                #if os(macOS)
                    model.newItem()
                #else
                    model.isCapturing = true
                #endif
            }
            .keyboardShortcut(KeyCommand.newItem)
            #if os(macOS)
                .disabled(!model.canAdd)
            #endif
            #if os(macOS)
                Button("New Subtask") { if let task = model.subtaskTarget { model.newSubtask(of: task) } }
                    .keyboardShortcut(KeyCommand.newSubtask)
                    .disabled(model.subtaskTarget == nil)
            #endif
        }
        #if os(macOS)
            CommandGroup(replacing: .importExport) {
                Button("Export as Markdown…") { model.exportMarkdown() }
                    .disabled(!model.canExportMarkdown)
                Button("Back Up…") { model.exportAll() }
                Button("Restore from Backup…") { model.isChoosingRestore = true }
            }
        #endif
        #if os(macOS)
            CommandGroup(before: .textEditing) {
                Button("Search") { model.isSearching = true }
                    .keyboardShortcut(KeyCommand.search)
                Divider()
            }
        #endif
        CommandMenu("Item") {
            item(.done, KeyCommand.done)
            item(.today, KeyCommand.today)
            Divider()
            item(.move(.action), KeyCommand.toActions)
            item(.move(.waiting), KeyCommand.toWaiting)
            item(.move(.someday), KeyCommand.toSomeday)
            item(.move(.reference), KeyCommand.toReference)
            item(.trash, KeyCommand.trash)
            item(.putBack)
            Divider()
            item(.arrange(.up))
            item(.arrange(.down))
            item(.arrange(.intoAbove))
            item(.arrange(.outOfTask))
            Divider()
            #if os(macOS)
                Menu("Details") {
                    detail("Title", KeyCommand.title)
                    Divider()
                    detail("Area…", KeyCommand.area)
                    detail("Task…", KeyCommand.task)
                    Divider()
                    detail("Scheduled…", KeyCommand.scheduled)
                    detail("Due…", KeyCommand.due)
                    detail("Repeat…", KeyCommand.repeats)
                    detail("Hide Until…", KeyCommand.hideUntil)
                    Divider()
                    detail("Contexts…", KeyCommand.contexts)
                    detail("Time…", KeyCommand.time)
                    detail("Energy…", KeyCommand.energy)
                    Divider()
                    detail("Waiting", KeyCommand.waitingFor)
                    detail("Follow Up…", KeyCommand.followUp)
                }
            #else
                item(.hideUntil, KeyCommand.hideUntil)
            #endif
            item(.showNow)
            item(.skip)
            Divider()
            item(.activate)
            item(.nudge)
            item(.takeBack)
            item(.moveToSomeday)
            item(.drop)
            Divider()
            item(.addAttachment)
            item(.copyOpenSubtasks)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.showsKeyCard = true }
                .keyboardShortcut(KeyCommand.card)
        }
        CommandMenu("Routines") {
            Button("Brain Dump…") { model.isBrainDumping = true }
            if model.isReviewing {
                Button("Finish Review") { model.finishReview() }
            } else {
                Button("Start Review") { model.startReview() }
            }
        }
    }

    /// An Item ▸ Details command: opens the detail's editor in the inspector, greyed when the open
    /// item or the selected rows don't all have it.
    private func detail(_ name: String, _ command: KeyCommand) -> some View {
        Button(name) { if let request = command.detail { model.edit(request) } }
            .keyboardShortcut(command)
            .disabled(!(command.detail.map(model.canEdit) ?? false))
    }

    /// The areas, in Settings' order.
    private var areas: [Area] {
        (try? model.context.fetch(FetchDescriptor<Area>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
    }

    /// A View ▸ Area item, ticked while the lists show that area (nil for all of them).
    private func areaToggle(_ name: String, _ area: UUID?) -> some View {
        Toggle(name, isOn: Binding(get: { model.area == area }, set: { if $0 { model.area = area } }))
    }

    /// An Item menu command, acting on the open item or the selected rows, with its chord, and
    /// greyed when it doesn't apply to them.
    private func item(_ action: ItemAction, _ command: KeyCommand? = nil) -> some View {
        let items = model.commandItems
        return Button(AppModel.name(of: action, for: items)) { model.perform(action, model.commandItems) }
            .keyboardShortcut(command)
            .disabled(!model.can(action, items))
    }
}

/// The app's store, and what works with it.
struct Store {
    let model: AppModel
    /// Where the store and sync's state are kept.
    let folder: URL

    /// The person's own store in the App Group container; in memory while the app's tests run.
    /// The first time, the store is copied there from Application Support. A build that can't use
    /// the App Group keeps it in Application Support.
    static func open() -> Result<Store, Error> {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return open(in: nil) }
        let earlier = URL.applicationSupportDirectory.appending(path: StoreFolder.name, directoryHint: .isDirectory)
        guard let folder = StoreFolder.shared else { return open(in: earlier) }
        return Result { try StoreFolder.fill(folder, from: earlier) }.flatMap { open(in: folder) }
    }

    /// The store in `base`, or in memory when it's nil. A store that `canSync` is false for never
    /// syncs.
    static func open(in base: URL?, canSync: Bool = true) -> Result<Store, Error> {
        Result {
            let folder = base ?? FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let container = try TasksSchema.container(at: base == nil ? nil : folder.appending(path: StoreFolder.storeName))
            try TasksSchema.seed(ModelContext(container))
            return Store(container: container, folder: folder, canSync: canSync)
        }
    }

    init(container: ModelContainer, folder: URL, canSync: Bool = true) {
        let cloudSync = CloudSync(container: container, folder: folder, canSync: canSync)
        model = AppModel(container: container, cloudSync: cloudSync)
        self.folder = folder
    }
}

/// The store the app has open.
@MainActor
final class Stores {
    let current: Result<Store, Error>

    /// Opens the store, and gives the app's delegate, and what it works with, its model as soon as
    /// it opens, whether or not a window shows it.
    init() {
        current = Store.open()
        if case .success(let store) = current { AppDelegate.model = store.model }
    }
}

/// Registers for the pushes that tell sync another device changed something, and on the Mac,
/// the quick-capture shortcut; there, it also turns off window tabs and opens the window again
/// when the Dock icon is clicked with none showing.
#if os(macOS)
    final class AppDelegate: NSObject, NSApplicationDelegate {
        @MainActor static weak var model: AppModel? {
            didSet {
                if let model { QuickCapturePanel.shared.model = model }
                Notifier.shared.model = model
            }
        }

        func applicationWillFinishLaunching(_ notification: Notification) {
            NSWindow.allowsAutomaticWindowTabbing = false
        }

        /// Asked to open again with no window showing, it lets SwiftUI open the main window.
        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
            !hasVisibleWindows
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            // With no window showing once it's started, it opens the main window.
            Task { @MainActor in
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { MainWindow.open() }
            }
            UNUserNotificationCenter.current().delegate = Notifier.shared
            NSApp.registerForRemoteNotifications()
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                QuickCapturePanel.shared.registerShortcut()
                QuickCapturePanel.shared.addStatusItem()
            }
            ListKeys.shared.start()
        }
    }
#else
    final class AppDelegate: NSObject, UIApplicationDelegate {
        @MainActor static weak var model: AppModel? {
            didSet { Notifier.shared.model = model }
        }

        func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil)
            -> Bool
        {
            UNUserNotificationCenter.current().delegate = Notifier.shared
            application.registerForRemoteNotifications()
            return true
        }
    }
#endif
