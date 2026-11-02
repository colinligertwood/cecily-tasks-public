import Foundation

/// A move of a list's selected rows from the keyboard.
public enum Arrangement: Sendable, CaseIterable {
    /// Before the row above, among the rows beside them.
    case up
    /// After the row below, among the rows beside them.
    case down
    /// To the end of the subtasks of the row above, among the rows beside them.
    case intoAbove
    /// Out from under their task, to just after it.
    case outOfTask
}

extension Clarifier {
    /// Whether `move` would change anything for `items` among `rows`.
    public static func canArrange(_ items: [Item], _ move: Arrangement, in rows: [ListRow]) -> Bool {
        arranging(items, move, in: rows) != nil
    }

    /// Moves `items`, rows among `rows` (a list's rows, or a part of one), together and in their
    /// order. The rows beside them are those at the top, or those under the same task's row. The
    /// rows must all be beside one another, and a nested row must be under its own task's. Rows
    /// at the top take their place in `order`, the whole list's items (`ListRow.order`), so the
    /// list's other parts keep theirs. Nil when nothing would move.
    public static func arrange(_ items: [Item], _ move: Arrangement, in rows: [ListRow], order: [Item]? = nil, at now: Date = .now) -> Undo? {
        arranging(items, move, in: rows, order: order)?(now)
    }

    /// What making `move` does, given the time it's made; nil when it would change nothing.
    private static func arranging(_ items: [Item], _ move: Arrangement, in rows: [ListRow], order: [Item]? = nil) -> ((Date) -> Undo?)? {
        let ids = Set(items.map(\.id))
        let chosen = rows.filter { ids.contains($0.id) }
        guard let first = chosen.first, let last = chosen.last else { return nil }
        let task = first.under
        func isBeside(_ row: ListRow) -> Bool { row.under?.id == task?.id && (task == nil || row.isUnderParent) }
        let beside = rows.filter(isBeside).map(\.item)
        guard chosen.allSatisfy(isBeside), let start = beside.firstIndex(where: { $0.id == first.id }),
            let end = beside.firstIndex(where: { $0.id == last.id })
        else { return nil }
        let moving = chosen.map(\.item)

        func put(before: Item?) -> (Date) -> Undo? {
            if let task { return { makeSubItems(moving, of: task, before: before, at: $0) } }
            let whole = order ?? beside
            let target = before ?? beside.last.flatMap { following($0, in: whole, leaving: Set(moving.map(\.id))) }
            return { place(moving, among: whole, before: target, at: $0)?.undo }
        }

        switch move {
        case .up:
            guard start > 0 else { return nil }
            return put(before: beside[start - 1])
        case .down:
            guard end + 1 < beside.count else { return nil }
            return put(before: end + 2 < beside.count ? beside[end + 2] : nil)
        case .intoAbove:
            guard start > 0 else { return nil }
            let above = beside[start - 1]
            guard moving.contains(where: { canMake($0, aSubItemOf: above) }) else { return nil }
            return { makeSubItems(moving, of: above, at: $0) }
        case .outOfTask:
            guard let task else { return outOfTasks(moving.filter { $0.parent != nil }) }
            guard let taskRow = rows.first(where: { $0.id == task.id }) else { return nil }
            if let outer = taskRow.under {
                guard taskRow.isUnderParent else { return nil }
                let subtasks = (outer.children ?? []).sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
                let next = subtasks.firstIndex { $0.id == task.id }.flatMap { subtasks.indices.contains($0 + 1) ? subtasks[$0 + 1] : nil }
                return { makeSubItems(moving, of: outer, before: next, at: $0) }
            }
            let top = rows.filter { $0.under == nil }.map(\.item)
            let next = top.firstIndex { $0.id == task.id }.flatMap { top.indices.contains($0 + 1) ? top[$0 + 1] : nil }
            return { now in
                let undo = Undo(moving + top, title: title(of: moving))
                for item in moving {
                    item.parent = task.parent
                    item.modifiedAt = now
                }
                _ = place(moving, among: top, before: next, at: now)
                return undo
            }
        }
    }

    /// Takes rows at the top out from under their tasks, each to its task's own, where it is in the list.
    private static func outOfTasks(_ items: [Item]) -> ((Date) -> Undo?)? {
        guard !items.isEmpty else { return nil }
        return { now in
            let undo = Undo(items, title: title(of: items))
            for item in items {
                item.parent = item.parent?.parent
                item.modifiedAt = now
            }
            return undo
        }
    }

    private static func title(of items: [Item]) -> String {
        items.count == 1 ? items[0].title : "\(items.count) items"
    }

    /// The item after `item` in `order`, leaving out those in `moving`; nil at the end.
    private static func following(_ item: Item, in order: [Item], leaving moving: Set<UUID>) -> Item? {
        guard let index = order.firstIndex(where: { $0.id == item.id }) else { return nil }
        return order[(index + 1)...].first { !moving.contains($0.id) }
    }

    /// Puts `items`, dropped at `index` among `rows`, one part of a list whose parts are
    /// `sections`: before the part's next row at the top, or just after its last, in the order of
    /// the whole list, so its other parts keep theirs. A task's subtasks, given as `project`, take
    /// in the items that can be made its subtasks. Nil when nothing would move.
    public static func place(
        _ items: [Item], at index: Int, in rows: [ListRow], of sections: [[ListRow]], project: Item? = nil, at now: Date = .now
    ) -> (undo: Undo, separated: Bool)? {
        let whole = ListRow.order(sections.contains(rows) ? sections : [rows])
        let moving = Set(items.map(\.id))
        let before = ListRow.nextItem(in: rows, at: index) ?? rows.last { !$0.isSubItem }.flatMap { following($0.item, in: whole, leaving: moving) }
        return place(items, among: whole, before: before, in: project, at: now)
    }

    /// Changes what puts `items` in an Actions group, for rows dragged from the group headed `from`
    /// into the one headed `to`: out of the context they were dragged from and into this one, or
    /// out of every context for Anywhere; into the area, or none; under the task, or out of the
    /// one they're under. False when it changes nothing.
    @discardableResult
    public static func regroup(_ items: [Item], from: ListGroup.Heading?, to: ListGroup.Heading, at now: Date = .now) -> Bool {
        let before = items.map(\.modifiedAt)
        for item in items {
            switch to {
            case .context(let context):
                if case .context(let old) = from, old.id != context.id { item.setContext(old, false, at: now) }
                item.setContext(context, true, at: now)
            case .noContext:
                for context in item.contexts ?? [] { item.setContext(context, false, at: now) }
            case .area(let area):
                item.setArea(area, at: now)
            case .noArea:
                item.setArea(nil, at: now)
            case .project(let task):
                item.setProject(task, at: now)
            case .noProject:
                item.setProject(nil, at: now)
            case .all:
                break
            }
        }
        return zip(items, before).contains { $0.modifiedAt != $1 }
    }
}

/// What one of a list's groups stands for, for rows dropped into it from another: the details
/// that put rows in it. A group whose rows can't be given what puts them there, such as the
/// Inbox's days, has none, and takes no rows from other groups.
public struct DropGroup {
    public let id: String
    public let headings: [ListGroup.Heading]

    public init(id: String, headings: [ListGroup.Heading]) {
        self.id = id
        self.headings = headings
    }
}

extension ListGroup {
    public var dropGroup: DropGroup { DropGroup(id: id, headings: [heading]) }
}

extension SomedayGroup {
    public var dropGroup: DropGroup { DropGroup(id: id, headings: [area.map { .area($0) } ?? .noArea]) }
}

extension ReferenceGroup {
    public var dropGroup: DropGroup {
        DropGroup(id: id, headings: [area.map { .area($0) } ?? .noArea, project.map { .project($0) } ?? .noProject])
    }
}

extension ListGroup.Heading {
    /// Whether it's about the same detail as `other`: both contexts, areas or tasks.
    fileprivate func isAboutTheSameDetail(as other: ListGroup.Heading) -> Bool {
        switch (self, other) {
        case (.context, .context), (.context, .noContext), (.noContext, .context), (.noContext, .noContext): true
        case (.area, .area), (.area, .noArea), (.noArea, .area), (.noArea, .noArea): true
        case (.project, .project), (.project, .noProject), (.noProject, .project), (.noProject, .noProject): true
        case (.all, .all): true
        default: false
        }
    }
}

extension Clarifier {
    /// Changes what puts `items` in a list's group, for rows dragged from the group `from` into
    /// `to`: each detail `to` stands for, from the same detail of `from` (`regroup(_:from:to:at:)`).
    /// False when it changes nothing.
    @discardableResult
    public static func regroup(_ items: [Item], from: DropGroup?, to: DropGroup, at now: Date = .now) -> Bool {
        var changed = false
        for heading in to.headings {
            let source = from?.headings.first { $0.isAboutTheSameDetail(as: heading) }
            changed = regroup(items, from: source, to: heading, at: now) || changed
        }
        return changed
    }
}

extension ListRow {
    /// The items at the top of a list's parts, each once, in the order the list puts them in: the
    /// order a row moved within one part takes its place in, so the other parts keep theirs.
    public static func order(_ sections: [[ListRow]]) -> [Item] {
        var seen = Set<UUID>()
        return sections.joined().filter { !$0.isSubItem && seen.insert($0.id).inserted }.map(\.item).sorted(by: Item.inListOrder)
    }
}
