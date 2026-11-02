import Foundation
import SwiftData
import TasksCore

/// A detail a key asks the inspector to open: the title, or one of the details.
enum DetailRequest: Equatable {
    case title
    case field(ItemField)
}

/// What the Item menu and its keys do to the items they act on.
enum ItemAction: Hashable {
    case done
    case today
    case move(Bucket)
    case trash
    case putBack
    case hideUntil
    case showNow
    case skip
    case activate
    case nudge
    case takeBack
    case moveToSomeday
    case drop
    case copyOpenSubtasks
    case addAttachment
    case arrange(Arrangement)
}

extension AppModel {
    /// The items the Item menu and its keys act on: the open item, or else the selected rows.
    var commandItems: [Item] {
        if let item = openTask { return [item] }
        let ids = Array(selection)
        guard !ids.isEmpty else { return [] }
        return (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
    }

    /// The menu's name for `action` on `items`.
    static func name(of action: ItemAction, for items: [Item]) -> String {
        switch action {
        case .done: !items.isEmpty && items.allSatisfy { $0.status == .done } ? "Mark as Not Done" : "Mark as Done"
        case .today: "Schedule for Today"
        case .move(let bucket): bucket == .waiting ? "Move to Waiting…" : "Move to \(bucket.title)"
        case .trash: "Move to Trash"
        case .putBack: "Put Back"
        case .hideUntil: "Hide Until…"
        case .showNow: "Show Now"
        case .skip: "Skip This One"
        case .activate: "Activate"
        case .nudge: "Nudge"
        case .takeBack: "Take Back"
        case .moveToSomeday: "Move Task to Someday"
        case .drop: "Drop Task"
        case .copyOpenSubtasks: "Copy Open Subtasks"
        case .addAttachment: "Add Attachment…"
        case .arrange(.up): "Move Up"
        case .arrange(.down): "Move Down"
        case .arrange(.intoAbove): "Move Into Task Above"
        case .arrange(.outOfTask): "Move Out of Task"
        }
    }

    /// Whether `action` does something to `items`: the same as when the list's context menu
    /// offers it, and for moving, whenever an item can go there from where it is.
    func can(_ action: ItemAction, _ items: [Item]) -> Bool {
        guard !items.isEmpty else { return false }
        let live = items.allSatisfy { $0.bucket != .trash }
        let single = items.count == 1 ? items.first : nil
        switch action {
        case .done:
            return live
        case .today:
            return items.contains { $0.canStart && $0.day(.scheduled) != today }
        case .move(let bucket):
            return live && items.contains { $0.bucket != bucket } && Self.canMove(items, to: bucket)
        case .trash:
            return live
        case .putBack:
            return items.contains { $0.bucket == .trash }
        case .hideUntil:
            return single != nil && live
        case .showNow:
            guard let single else { return false }
            return single.hideUntil != nil && single.isHidden(today: today)
        case .skip:
            return items.allSatisfy { $0.status == .open && $0.repeatRule != nil }
        case .activate:
            return items.contains { $0.bucket == .someday }
        case .nudge, .takeBack:
            return items.contains { $0.bucket == .waiting }
        case .moveToSomeday:
            guard let single else { return false }
            return single.isProject && single.status == .open && single.bucket != .someday && single.bucket != .trash
        case .drop:
            guard let single else { return false }
            return single.isProject && single.status == .open && single.bucket != .trash
        case .copyOpenSubtasks:
            guard let single else { return false }
            return !MarkdownExport.openSubtasks(of: single).isEmpty
        case .addAttachment:
            return single != nil && live
        case .arrange(let move):
            guard openItem == nil, let rows = arrangeableRows(of: items) else { return false }
            guard arrangeableReorders || (move != .up && move != .down) else { return false }
            return Clarifier.canArrange(items, move, in: rows)
        }
    }

    /// The part of the list showing that has all of `items`, for moving them; nil when there's
    /// none.
    private func arrangeableRows(of items: [Item]) -> [ListRow]? {
        arrangeableRows.first { rows in items.allSatisfy { item in rows.contains { $0.id == item.id } } }
    }

    /// Notes stay notes: they can go to Someday and Reference, but not Actions or Waiting.
    private static func canMove(_ items: [Item], to bucket: Bucket) -> Bool {
        switch bucket {
        case .action, .waiting: items.allSatisfy { $0.kind == .action }
        case .someday, .reference: true
        case .inbox, .trash: false
        }
    }

    /// Does `action` to `items`, when it can.
    func perform(_ action: ItemAction, _ items: [Item]) {
        guard can(action, items) else { return }
        switch action {
        case .done: toggleDone(items)
        case .today: startToday(items)
        case .move(.waiting): askingWaitingFor = items.filter { $0.bucket != .waiting }
        case .move(let bucket): move(items, to: bucket)
        case .trash: file(items, ClarifyOutcome(.trash))
        case .putBack: putBack(items)
        case .hideUntil: hiding = items.first
        case .showNow: if let item = items.first { hide(item, until: nil) }
        case .skip: skip(items)
        case .activate: activate(items)
        case .nudge: nudge(items)
        case .takeBack: takeBack(items)
        case .moveToSomeday: if let item = items.first { moveToSomeday(item) }
        case .drop: if let item = items.first { drop(item) }
        case .copyOpenSubtasks: if let item = items.first { copyOpenSubtasks(of: item) }
        case .addAttachment: attachingTo = items.first
        case .arrange(let move):
            guard let rows = arrangeableRows(of: items) else { return }
            let name = Self.name(of: action, for: items)
            record(Clarifier.arrange(items, move, in: rows, order: ListRow.order(arrangeableRows)), named: name)
            if move == .intoAbove, let task = items.first?.parent { settle(items, under: task, named: name) }
        }
    }

    /// Moves the items to `bucket` from wherever they are, each the way its list does: filed from
    /// the Inbox and Reference, activated from Someday, taken back from Waiting, and a task with
    /// subtasks moved to Someday with them.
    private func move(_ items: [Item], to bucket: Bucket) {
        let moving = items.filter { $0.bucket != bucket }
        switch bucket {
        case .action:
            let fromSomeday = moving.filter { $0.bucket == .someday }
            let fromWaiting = moving.filter { $0.bucket == .waiting }
            let rest = moving.filter { $0.bucket != .someday && $0.bucket != .waiting }
            if !fromSomeday.isEmpty { activate(fromSomeday) }
            if !fromWaiting.isEmpty { takeBack(fromWaiting) }
            if !rest.isEmpty { file(rest, ClarifyOutcome(.action)) }
        case .someday:
            let tasks = moving.filter { $0.isProject && $0.status == .open }
            for task in tasks { moveToSomeday(task) }
            let rest = moving.filter { !($0.isProject && $0.status == .open) }
            if !rest.isEmpty { file(rest, ClarifyOutcome(.someday)) }
        case .waiting:
            file(moving, ClarifyOutcome(.waiting(person: "", followUp: nil)))
        case .reference:
            file(moving, ClarifyOutcome(.reference))
        case .inbox, .trash:
            break
        }
    }

    /// Goes to `page`, as choosing it in the sidebar does; on Agenda already, to Today's stop.
    func go(to page: Page) {
        if page == .agenda, self.page == .agenda, searchText.isEmpty, openItem == nil, openEvent == nil {
            timelineStop = nil
            return
        }
        show(page)
        searchText = ""
        isSearching = false
    }

    /// Moves the items to Waiting, waiting for `person`.
    func moveToWaiting(_ items: [Item], for person: String) {
        let moving = items.filter { $0.bucket != .waiting && $0.bucket != .trash && $0.kind == .action }
        guard !moving.isEmpty else { return }
        file(moving, ClarifyOutcome(.waiting(person: person.trimmingCharacters(in: .whitespaces), followUp: nil)))
    }

    /// Whether `request` applies to every item the keys act on: the title to one item, and a
    /// detail to items that all have it in the inspector (who it's waiting for, to one).
    func canEdit(_ request: DetailRequest) -> Bool {
        let items = commandItems
        switch request {
        case .title:
            return items.count == 1 && items[0].bucket != .trash
        case .field(let field):
            guard !items.isEmpty, field != .waitingFor || items.count == 1 else { return false }
            return items.allSatisfy { $0.inspectableFields.contains(field) }
        }
    }

    /// Opens `request`'s editor in the inspector, showing it if it's hidden, for the open item or
    /// the selected rows.
    func edit(_ request: DetailRequest) {
        guard canEdit(request) else { return }
        if let item = openItem, !selection.contains(item) { selection = [item] }
        showsInspector = true
        detailRequest = request
    }
}
