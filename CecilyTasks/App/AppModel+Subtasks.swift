import Foundation
import SwiftData
import TasksCore

extension AppModel {
    /// Saves a decision and registers its undo under `name`.
    func record(_ undo: Clarifier.Undo?, named name: String) {
        guard let undo else { return }
        save()
        register([undo], named: name)
    }

    /// Adds an action to follow up each waiting item, at the top of Actions in Calls.
    func nudge(_ items: [Item]) {
        let undos = items.filter { $0.bucket == .waiting }.map { Clarifier.nudge($0, in: context) }
        guard !undos.isEmpty else { return }
        save()
        register(undos, named: "Nudge")
    }

    /// Gives the items a repeat, described as `text`, or stops them repeating when `rule` is nil,
    /// as a step that can be undone.
    func setRepeat(_ items: [Item], _ rule: RepeatRule?, text: String) {
        setRepeats(items.map { ($0, rule, text) })
    }

    /// Changes the repeat of items that already repeat, moving each to the new rule's first date
    /// from today: for all upcoming copies, or with `thisOneOnly`, for these copies only, keeping
    /// their rules. One step that can be undone.
    func changeRepeat(_ items: [Item], to rule: RepeatRule, text: String, thisOneOnly: Bool) {
        let undos = items.map { item in
            let records: [any SyncModel] = [item] + [item.repeatRule].compactMap { $0 }
            return Clarifier.Undo(records, title: item.title)
        }
        for item in items {
            RepeatCopies.change(item, to: rule, text: text, thisOneOnly: thisOneOnly, today: today, in: context)
        }
        save()
        register(undos, named: thisOneOnly ? "Change This One" : ItemField.repeats.undoName)
    }

    /// Closes the repeating items without marking them done, and makes their next copies.
    func skip(_ items: [Item]) {
        record(RepeatCopies.skip(items, today: today, in: context), named: "Skip This One")
    }

    /// Gives each item its repeat, and registers putting back the ones they had.
    private func setRepeats(_ repeats: [(item: Item, rule: RepeatRule?, text: String)]) {
        let before = repeats.map { ($0.item, $0.item.repeatRule?.rule, $0.item.repeatRule?.naturalText ?? "") }
        for (item, rule, text) in repeats { item.setRepeat(rule, text: text, in: context) }
        save()
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in model.setRepeats(before) }
        undoManager.setActionName(ItemField.repeats.undoName)
    }

    /// Moves Someday's items to Actions, and makes its projects active.
    func activate(_ items: [Item]) {
        record(Clarifier.activate(items), named: "Activate")
    }

    /// Moves waiting items to Actions, to do them yourself.
    func takeBack(_ items: [Item]) {
        record(Clarifier.takeBack(items), named: "Take Back")
    }

    /// Moves the task to Someday, with its subtasks out of every list.
    func moveToSomeday(_ project: Item) {
        record(Clarifier.moveToSomeday(project), named: "Move to Someday")
        if openItem == project.id { openItem = nil }
    }

    /// Drops the task, with its subtasks out of every list.
    func drop(_ project: Item) {
        record(Clarifier.drop(project), named: "Drop")
        if openItem == project.id { openItem = nil }
    }

    /// Hides the item until `day`, or shows it now when `day` is nil.
    func hide(_ item: Item, until day: LocalDate?) {
        let name = day == nil ? "Show Now" : item.isProject ? "Hide Project" : "Hide Item"
        record(Clarifier.hide(item, until: day), named: name)
        if day != nil, openItem == item.id { openItem = nil }
    }

    /// What dragging `item`'s row carries, when the drag starts: the IDs of every selected row
    /// when it's one of them, otherwise its own. `group` is the list's group it's dragged from.
    func dragged(_ item: Item, from group: DropGroup? = nil) -> String {
        dragging = selection.contains(item.id) ? Array(selection) : [item.id]
        draggedFrom = group
        return dragging.map(\.uuidString).joined(separator: "\n")
    }

    /// Whether any of the rows being dragged can go under `parent`, before its sub-item `before`.
    func canDrop(onto parent: Item, before: Item?) -> Bool {
        items(Set(dragging)).contains { Self.canGo($0, under: parent, before: before) }
    }

    /// Whether `item` can go under `parent`, before its sub-item `before`: as a new sub-item, or
    /// moving among `parent`'s own.
    private static func canGo(_ item: Item, under parent: Item, before: Item?) -> Bool {
        Clarifier.canMake(item, aSubItemOf: parent) || (before != nil && item.parent?.id == parent.id && item.id != before?.id)
    }

    func items(dragged payloads: [String]) -> [Item] {
        items(Set(payloads.flatMap { $0.split(separator: "\n").compactMap { UUID(uuidString: String($0)) } }))
    }

    private func items(_ ids: Set<UUID>) -> [Item] {
        let found = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        return found.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    /// Puts dragged rows dropped on the line before `rows[index]`, or after the last, in the
    /// list's order, so its other parts keep theirs (`Clarifier.place(_:at:in:of:)`). A project's
    /// list, given as `project`, takes them in. Dropped into another of the list's groups, `group`,
    /// they're moved into it (`Clarifier.regroup`), unless it's one rows can't be moved into.
    func drop(_ payloads: [String], at index: Int, in rows: [ListRow], project: Item? = nil, into group: DropGroup? = nil) {
        let moving = items(dragged: payloads)
        let sections = arrangeableRows.contains(rows) ? arrangeableRows : [rows]
        if let group, group.id != draggedFrom?.id {
            guard !group.headings.isEmpty else { return }
            let movingIDs = Set(moving.map(\.id))
            let others = ListRow.order(sections).filter { !movingIDs.contains($0.id) }
            let undo = Clarifier.Undo(moving + others, title: moving.count == 1 ? moving[0].title : "\(moving.count) items")
            let regrouped = Clarifier.regroup(moving, from: draggedFrom, to: group)
            let placed = Clarifier.place(moving, at: index, in: rows, of: sections, project: project)
            guard regrouped || placed != nil else { return }
            record(undo, named: "Move")
        } else {
            guard let placed = Clarifier.place(moving, at: index, in: rows, of: sections, project: project) else { return }
            record(placed.undo, named: placed.separated ? "Move Out of Item" : "Move")
        }
        selection = []
    }

    /// Puts the dragged rows under `parent`, before its sub-item `before` or after the others,
    /// and shows them under it in the lists for a few seconds (`settle`). False when none of them
    /// can go there.
    @discardableResult
    func drop(_ payloads: [String], onto parent: Item, before: Item? = nil) -> Bool {
        let moving = items(dragged: payloads).filter {
            Clarifier.canMake($0, aSubItemOf: parent) || (before != nil && $0.parent?.id == parent.id)
        }
        let wasUnder = moving.allSatisfy { $0.parent?.id == parent.id }
        guard let undo = Clarifier.makeSubItems(moving, of: parent, before: before) else { return false }
        let name = wasUnder ? "Move" : moving.count == 1 ? "Make Sub-item" : "Make Sub-items"
        record(undo, named: name)
        if !wasUnder, openItem == nil {
            settle(moving, under: parent, named: name)
        } else {
            selection = []
        }
        return true
    }

    /// The Inbox, oldest first.
    func inbox() -> [Item] {
        let inbox = Bucket.inbox.rawValue
        let open = ItemStatus.open.rawValue
        let descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.bucketRaw == inbox && $0.statusRaw == open }, sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Makes a change to an item, with one of its setters, and saves it.
    func edit(_ item: Item, _ change: (Item) -> Void) {
        change(item)
        save()
    }

    /// Makes a change to an area, with one of its setters, and saves it.
    func edit(_ area: Area, _ change: (Area) -> Void) {
        change(area)
        save()
    }

    /// Makes a change to a context, with one of its setters, and saves it.
    func edit(_ context: Context, _ change: (Context) -> Void) {
        change(context)
        save()
    }
}
