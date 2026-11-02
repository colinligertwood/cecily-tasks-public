import Foundation
import SwiftData

// Decisions about tasks and their subtasks, made without saving. Each returns how things were, so
// it can be undone with `Clarifier.undo`, or nil when it would change nothing.

extension Clarifier {
    /// Moves the task to Someday, taking its subtasks out of every list.
    public static func moveToSomeday(_ project: Item, at now: Date = .now) -> Undo? {
        guard project.bucket != .someday, project.bucket != .trash else { return nil }
        let undo = Undo([project], title: project.title)
        project.bucket = .someday
        project.modifiedAt = now
        return undo
    }

    /// Drops the task. Its subtasks stay as they are, out of every list while it's dropped.
    public static func drop(_ project: Item, at now: Date = .now) -> Undo? {
        guard project.status != .dropped else { return nil }
        let undo = Undo([project], title: project.title)
        project.status = .dropped
        project.completedAt = now
        project.modifiedAt = now
        return undo
    }

    /// Hides the item until `day`, or shows it again when `day` is nil.
    public static func hide(_ item: Item, until day: LocalDate?, at now: Date = .now) -> Undo? {
        guard day?.storedDate != item.hideUntil else { return nil }
        let undo = Undo([item], title: item.title)
        item.hideUntil = day?.storedDate
        item.modifiedAt = now
        return undo
    }

    /// Whether `item` can be made a subtask of `parent`: it isn't `parent`, already under it, or
    /// above it, and with its own subtasks it would be no deeper than `Item.deepestSubItem`.
    public static func canMake(_ item: Item, aSubItemOf parent: Item) -> Bool {
        guard item.id != parent.id, item.parent?.id != parent.id, !parent.ancestors.contains(where: { $0.id == item.id }) else { return false }
        return parent.depth + 1 + item.subItemLevels <= Item.deepestSubItem
    }

    /// Puts `items` under `parent`, in their order, before the subtask `before` or after the
    /// others. Each keeps its own details. Items that can't go there are left as they are;
    /// subtasks already under `parent` move to the new place.
    public static func makeSubItems(_ items: [Item], of parent: Item, before: Item? = nil, at now: Date = .now) -> Undo? {
        let moving = items.filter { canMake($0, aSubItemOf: parent) || ($0.parent?.id == parent.id && $0.id != before?.id) }
        guard !moving.isEmpty else { return nil }
        let movingIDs = Set(moving.map(\.id))
        var order = (parent.children ?? []).filter { !movingIDs.contains($0.id) }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        let siblings = order
        order.insert(contentsOf: moving, at: before.flatMap { b in order.firstIndex { $0.id == b.id } } ?? order.count)
        let undo = Undo(moving + siblings, title: moving.count == 1 ? moving[0].title : "\(moving.count) items")
        for item in moving where item.parent?.id != parent.id {
            item.parent = parent
            item.modifiedAt = now
        }
        Item.putInOrder(order, at: now)
        return undo
    }

    /// Puts `items` among `list`, a list's items in its order, before `before` or at the end. A
    /// task's subtasks, given as `project`, take in the items that can be made its subtasks. Nil
    /// when nothing would move. `separated` is always false: moving a subtask in a list leaves it
    /// under its task.
    public static func place(_ items: [Item], among list: [Item], before: Item?, in project: Item? = nil, at now: Date = .now)
        -> (undo: Undo, separated: Bool)?
    {
        let moving = items.filter { $0.id != before?.id }
        guard !moving.isEmpty else { return nil }
        let movingIDs = Set(moving.map(\.id))
        var order = list.filter { !movingIDs.contains($0.id) }
        order.insert(contentsOf: moving, at: before.flatMap { b in order.firstIndex { $0.id == b.id } } ?? order.count)
        let joining = project.map { project in moving.filter { canMake($0, aSubItemOf: project) } } ?? []
        guard !joining.isEmpty || order.map(\.id) != list.map(\.id) else { return nil }
        let undo = Undo(moving + order.filter { !movingIDs.contains($0.id) }, title: moving.count == 1 ? moving[0].title : "\(moving.count) items")
        for item in joining {
            item.parent = project
            item.modifiedAt = now
        }
        Item.putInOrder(order, at: now)
        return (undo, false)
    }
}
