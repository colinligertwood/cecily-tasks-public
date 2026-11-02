import SwiftData
import SwiftUI
import TasksCore

/// The lists, in the sidebar's order.
enum Page: String, CaseIterable, Identifiable, Hashable {
    case agenda = "Agenda"
    case inbox = "Inbox"
    case actions = "Actions"
    case waiting = "Waiting"
    case someday = "Someday"
    case reference = "Reference"
    case trash = "Trash"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .agenda: "calendar"
        case .inbox: "tray"
        case .actions: "checklist"
        case .waiting: "hourglass"
        case .someday: "moon.zzz"
        case .reference: "books.vertical"
        case .trash: "trash"
        }
    }

    /// The list it is in the weekly review, if it's one of them.
    var reviewList: ReviewList? {
        switch self {
        case .agenda: .agenda
        case .inbox: .inbox
        case .actions: .actions
        case .waiting: .waiting
        case .someday: .someday
        case .reference, .trash: nil
        }
    }

    init(_ list: ReviewList) {
        switch list {
        case .agenda: self = .agenda
        case .inbox: self = .inbox
        case .actions: self = .actions
        case .waiting: self = .waiting
        case .someday: self = .someday
        }
    }

    var view: some View {
        Group {
            switch self {
            case .agenda: AgendaView()
            case .inbox: InboxView()
            case .actions: ActionsView()
            case .waiting: WaitingView()
            case .someday: SomedayView()
            case .reference: ReferenceView()
            case .trash: TrashView()
            }
        }
        .listTitleMenu(self)
    }
}

/// The window: a sidebar on the Mac, tabs on iPhone, with capture and the brain dump
/// over them.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloudSync
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "inbox" && $0.statusRaw == "open" }) private var inbox: [Item]
    @AppStorage("brain-dump-offered") private var brainDumpOffered = false
    @State private var welcoming = false
    @State private var startsBrainDump = false

    var body: some View {
        @Bindable var model = model
        navigation
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { _, undoManager in model.undoManager = undoManager }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.readOutsideSaves()
                    model.refreshToday()
                    model.updateNotifications()
                    CalendarFeed.shared.refresh()
                }
            }
            .onChange(of: cloudSync.revision) {
                model.refreshReview()
                model.updateNotifications()
            }
            .onChange(of: model.today) {
                model.updateNotifications()
                CalendarFeed.shared.reload()
            }
            // While the app is open, the calendars are checked for what's changed every
            // `CalendarFeed.checkMinutes` minutes.
            .task(id: CalendarFeed.shared.checkMinutes) {
                let minutes = CalendarFeed.shared.checkMinutes
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(minutes * 60))
                    guard !Task.isCancelled else { return }
                    CalendarFeed.shared.refresh()
                }
            }
            .sheet(isPresented: $model.isCapturing) { CaptureSheet() }
            .sheet(isPresented: $model.isBrainDumping) { BrainDumpView() }
            .exportPanels()
            .attachmentPanels()
            .sheet(isPresented: $model.showsKeyCard) { KeyCard() }
            .sheet(item: $model.hiding) { HideUntilSheet(item: $0) }
            .sheet(isPresented: Binding(get: { model.askingWaitingFor != nil }, set: { if !$0 { model.askingWaitingFor = nil } })) {
                WaitingForSheet(items: model.askingWaitingFor ?? [])
            }
            // The brain dump opens once the welcome's sheet has closed.
            .sheet(isPresented: $welcoming) {
                if startsBrainDump {
                    startsBrainDump = false
                    model.isBrainDumping = true
                }
            } content: {
                WelcomeSheet { startsBrainDump = true }
            }
            .task {
                if WelcomeSheet.isForced {
                    welcoming = true
                    return
                }
                guard !brainDumpOffered else { return }
                brainDumpOffered = true
                if inbox.isEmpty { welcoming = true }
            }
    }

    /// The Inbox's count: its open items that are listed, not hidden until a later day or under a
    /// task that's gone.
    private var inboxCount: Int { inbox.count { $0.isListed(today: model.today, doneSince: nil) } }

    @ViewBuilder private var navigation: some View {
        #if os(macOS)
            MacNavigation(inboxCount: inboxCount)
        #else
            PhoneNavigation(inboxCount: inboxCount)
        #endif
    }
}

#Preview(traits: .previewRecords) {
    RootView()
}
