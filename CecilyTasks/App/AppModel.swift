import Foundation
import OSLog
import Observation
import SwiftData
import TasksCore

/// What the windows share: the store, sync, capture, and filing decisions with their undo.
/// Every change is saved as it's made, in the main context, which also sees what sync writes.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let cloudSync: CloudSync

    /// Quick capture is open in the window.
    var isCapturing = false
    /// The brain dump is open.
    var isBrainDumping = false
    /// Whether Empty Trash… is asking first.
    var isEmptyingTrash = false
    /// The list showing.
    var page: Page = .agenda
    /// The list open in More on iPhone.
    var morePage: Page?
    /// Where New Item or New Subtask last asked for a draft to start, until that view takes it.
    var draftRequest: DraftRequest?
    /// The item expanded over the list.
    var openItem: UUID? {
        didSet { if openItem != nil { openEvent = nil } }
    }
    /// The calendar event expanded over the list, in place of an item.
    var openEvent: CalendarEvent? {
        didSet { if openEvent != nil { openItem = nil } }
    }
    /// The items selected in the list showing.
    var selection: Set<UUID> = []
    /// The area the lists are narrowed to, or nil for every area.
    var area: UUID?
    /// What Actions is narrowed to, from the View menu.
    var actionsFilter = ActionsFilter()
    /// The item whose row's inspector popover is open, on iPhone and iPad.
    var inspecting: UUID?
    /// Whether the inspector is shown beside the list on the Mac.
    var showsInspector = true
    /// The search field's words.
    var searchText = ""
    /// Whether the search field is open and has the focus.
    var isSearching = false
    /// What search is narrowed to beyond its words.
    var searchFilter = ItemSearch.Filter()
    /// Whether the search field has no words in it, so there's nothing to find.
    var isSearchEmpty: Bool { searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The stop Agenda's timeline is narrowed to, or nil for Today.
    var timelineStop: TimelineStop?
    /// A step along Agenda's timeline asked for from the keyboard: -1 for the stop before, 1 for
    /// the one after. Agenda takes it and sets it back to nil.
    var timelineStep: Int?
    /// The letter Waiting is narrowed to, or nil for everyone.
    var waitingTab: WaitingTab?
    /// Whether the lists show items hidden until a later day, dimmed, from the View menu.
    var showsHidden = false
    /// The part of Settings open as a sheet on iPhone.
    var settingsSheet: SettingsPane?
    /// The item Hide Until is open for.
    var hiding: Item?
    /// The items Move to Waiting is asking who they're waiting for.
    var askingWaitingFor: [Item]?
    /// The detail a key asked the inspector to open, until it has.
    var detailRequest: DetailRequest?
    /// Whether the keyboard shortcuts' card is showing.
    var showsKeyCard = false
    /// What the save panel is open for.
    var exporting: ExportRequest?
    /// Whether the panel to choose an export to restore is open.
    var isChoosingRestore = false
    /// How many items a restore brought back, until that's been said.
    var restored: Int?
    /// Why the last export or restore didn't work, until that's been said.
    var exportProblem: String?
    /// The item Add Attachment… is choosing files for.
    var attachingTo: Item?
    /// The item Take Photo is open for, on iPhone and iPad.
    var photographing: Item?
    /// The item Scan Document is open for, on iPhone and iPad.
    var scanning: Item?
    /// Why the last files couldn't be added, until that's been said.
    var attachmentProblem: AttachmentProblem?
    /// Why the last change couldn't be saved, if it couldn't.
    private(set) var problem: String?
    /// The window's undo manager, which every decision is registered with under its name, for Edit
    /// ▸ Undo and Redo.
    @ObservationIgnored var undoManager: UndoManager?
    /// Goes up when the Share Sheet has added items, so the lists read them.
    private(set) var outsideRevision = 0
    /// The day it is, by the day boundary in settings. `refreshToday()` moves it on.
    private(set) var today = DayBoundary().day(at: .now, in: .current)
    /// When each day starts, from the settings.
    private(set) var boundary = DayBoundary()
    /// Whether a weekly review is open, so the app is in review mode. `refreshReview()` updates it.
    private(set) var isReviewing = false
    /// When `today` started. Items done since then stay in their lists, struck through.
    private(set) var dayStart = DayBoundary().start(of: DayBoundary().day(at: .now, in: .current), in: .current)

    @ObservationIgnored private var outsideSaves: OutsideSaves
    @ObservationIgnored private let log = Logger(subsystem: "com.ligertwood.cecily.tasks", category: "editing")
    @ObservationIgnored private var nextDay: Task<Void, Never>?
    /// The rows being dragged, from when the drag started, and the group of the list they were
    /// dragged from, when it has groups.
    @ObservationIgnored var dragging: [UUID] = []
    @ObservationIgnored var draggedFrom: DropGroup?
    /// The rows of the list showing, by part, for moving them from the keyboard; empty when its
    /// rows can't be moved.
    @ObservationIgnored var arrangeableRows: [[ListRow]] = []
    /// Whether the list showing can be put in order by hand, which a list sorted otherwise can't.
    @ObservationIgnored var arrangeableReorders = true
    /// Rows just put under a task, shown nested under it for a few seconds before the lists settle.
    var settling: Settling?
    @ObservationIgnored var settlingEnd: Task<Void, Never>?

    init(container: ModelContainer, cloudSync: CloudSync) {
        self.container = container
        self.cloudSync = cloudSync
        outsideSaves = OutsideSaves(container)
        refreshToday()
        refreshReview()
        deleteOldTrash()
    }

    var context: ModelContext { container.mainContext }

    /// Sets `today` from the clock, and again when the next day starts.
    func refreshToday() {
        let settings = try? context.fetch(FetchDescriptor<AppSettings>()).first
        let boundary = DayBoundary(minutes: settings?.dayBoundaryTime ?? DayBoundary().minutes)
        if boundary != self.boundary { self.boundary = boundary }
        let now = Date.now
        let day = boundary.day(at: now, in: .current)
        if day != today {
            today = day
            timelineStop = nil
            deleteOldTrash()
        }
        let start = boundary.start(of: day, in: .current)
        if start != dayStart { dayStart = start }
        let wait = boundary.nextStart(after: now, in: .current).timeIntervalSince(now)
        nextDay?.cancel()
        nextDay = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.refreshToday()
        }
    }

    /// Sets `isReviewing` from the store, after saves and sync.
    func refreshReview() {
        let open = WeeklyReview.current(reviews) != nil
        if open != isReviewing { isReviewing = open }
    }

    // MARK: Saving

    /// Picks up what the Share Sheet saved while the app was in the background: sync sends it,
    /// and the lists show it.
    func readOutsideSaves() {
        cloudSync.noteLocalChanges()
        if outsideSaves.check(container) { outsideRevision += 1 }
    }

    func save() {
        do {
            try context.save()
            problem = nil
        } catch {
            log.error("Couldn't save: \(error.localizedDescription, privacy: .public)")
            problem = "Couldn't save that change. \(error.localizedDescription)"
        }
        cloudSync.noteLocalChanges()
        refreshReview()
        updateNotifications()
    }

    /// Brings the pending notifications up to date with the store.
    func updateNotifications() {
        Notifier.shared.update(from: context)
    }

    /// What Edit ▸ Undo calls filing to `destination`: "Undo File in Someday".
    static func undoName(of destination: ClarifyOutcome.Destination) -> String {
        switch destination {
        case .trash: "Move to Trash"
        case .someday: "File in Someday"
        case .reference: "File in Reference"
        case .doneNow: "Mark as Done"
        case .waiting: "File in Waiting"
        case .scheduled: "Schedule for Today"
        case .action: "File in Actions"
        }
    }
}
