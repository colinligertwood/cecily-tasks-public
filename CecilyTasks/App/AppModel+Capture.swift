import Foundation
import SwiftData
import TasksCore

extension AppModel {
    /// Adds each line of `text` to the Inbox, or to `list`'s place, in the area the lists are
    /// narrowed to. The number of items added.
    @discardableResult
    func capture(_ text: String, source: ItemSource = .quickAdd, to list: Page = .inbox) -> Int {
        let (bucket, scheduled) = Self.place(of: list, today: today)
        let items = Capture.add(text, source: source, today: today, area: area, bucket: bucket, scheduled: scheduled, in: context)
        guard !items.isEmpty else { return 0 }
        save()
        return items.count
    }

    /// Adds quick entry's item to the Inbox: its first line the title, the rest its notes, with
    /// `details`, in the area the lists are narrowed to unless another's chosen. False when its
    /// first line has no title.
    @discardableResult
    func add(entry text: String, details: CaptureDetails) -> Bool {
        guard Capture.add(entry: text, details: details, area: area, source: .quickAdd, today: today, in: context) != nil else { return false }
        save()
        return true
    }

    /// Where an item added to `list` goes: its bucket, and its day for Scheduled.
    static func place(of list: Page, today: LocalDate) -> (bucket: Bucket, scheduled: LocalDate?) {
        switch list {
        case .inbox: (.inbox, nil)
        case .actions: (.action, nil)
        case .agenda: (.action, today)
        case .waiting: (.waiting, nil)
        case .someday: (.someday, nil)
        case .reference: (.reference, nil)
        case .trash: (.inbox, nil)
        }
    }

    /// The task open over the list.
    var openTask: Item? {
        guard let id = openItem else { return nil }
        return try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
    }

    /// Goes from the open task to the one it's a subtask of, or closes it when it has none.
    func back() {
        openItem = openTask?.parent?.id
    }

    /// Whether New Item has somewhere to add to: not the Trash, unless a task is open.
    var canAdd: Bool { page != .trash || openTask != nil }

    /// The task New Subtask is for: the one that's open, or the one row selected.
    var subtaskTarget: Item? {
        if let task = openTask { return task }
        guard selection.count == 1, let id = selection.first else { return nil }
        return try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
    }

    /// Opens `task` and starts a new subtask of it at the end of its subtasks.
    func newSubtask(of task: Item) {
        openItem = task.id
        newSubItem(of: task)
    }

    /// Starts a new item at the top of `list`, or of the list showing (a subtask of the open task
    /// when one's open), in the area the lists are narrowed to. On Agenda it starts on the chosen
    /// stop's first day, or on no day in Later.
    func newItem(in list: Page? = nil) {
        if list == nil, let task = openTask {
            newSubItem(of: task)
            return
        }
        let target = list ?? page
        guard target != .trash else { return }
        var (bucket, scheduled) = Self.place(of: target, today: today)
        if target == .agenda, let stop = timelineStop { scheduled = stop.kind == .later ? nil : stop.first }
        searchText = ""
        selection = []
        draftRequest = DraftRequest(target: .list(target), draft: NewItemDraft(.list(bucket: bucket, scheduled: scheduled, area: area)))
    }

    /// Starts a new subtask at the end of `item`'s, in its card.
    func newSubItem(of item: Item) {
        guard let draft = NewItemDraft.subtask(of: item) else { return }
        selection = []
        draftRequest = DraftRequest(target: .card(item.id), draft: draft)
    }

    /// The draft asked for `target`, which it takes, if there is one.
    func takeDraft(for target: DraftRequest.Target) -> NewItemDraft? {
        guard let request = draftRequest, request.target == target else { return nil }
        draftRequest = nil
        return request.draft
    }

    /// Makes the item a draft was typed for, as a decision that can be undone: New Item or New
    /// Subtask.
    @discardableResult
    func make(_ draft: NewItemDraft) -> Item? {
        guard let made = draft.make(in: context) else { return nil }
        if case .subtask = draft.place {
            record(made.undo, named: "New Subtask")
        } else {
            record(made.undo, named: "New Item")
        }
        return made.item
    }
}

/// Where New Item or New Subtask asks for a new item's draft to start, and the draft: in a list,
/// or among the subtasks of the task with an ID, in its card. The view it names takes it.
struct DraftRequest: Equatable {
    enum Target: Equatable {
        case list(Page)
        case card(UUID)
    }

    let target: Target
    let draft: NewItemDraft
    /// Tells one request from another for the same place, so asking again is seen.
    private let id = UUID()
}
