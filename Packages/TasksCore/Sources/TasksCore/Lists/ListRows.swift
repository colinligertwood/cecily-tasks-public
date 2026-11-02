import Foundation

/// A row in a list: an item, how many rows it's nested under, which indents it, and the item of
/// the row it's directly under, whose details it needn't repeat.
public struct ListRow: Identifiable {
    public let item: Item
    public let depth: Int
    public let under: Item?

    public init(item: Item, depth: Int = 0, under: Item? = nil) {
        self.item = item
        self.depth = depth
        self.under = under
    }

    /// Whether the row it's under is its own task's, so its Project tag would only repeat it.
    public var isUnderParent: Bool { under.map { $0.id == item.parent?.id } ?? false }

    public var isSubItem: Bool { depth > 0 }
    public var id: UUID { item.id }
}

extension ListRow {
    /// A list's rows by part, while rows just put under `task` settle: each of `moved` that's
    /// under the task now is taken from wherever it is, with what's nested under it, and nested
    /// under the task's first row, after what's under it already. The parts stay as they are, in
    /// their order, and a moved row that's no longer under the task, as after an undo, stays where
    /// it is. Nothing changes when the task has no row.
    public static func settling(_ sections: [[ListRow]], under task: UUID, moved: Set<UUID>) -> [[ListRow]] {
        guard let target = sections.firstIndex(where: { $0.contains { $0.id == task } }) else { return sections }
        func isMoving(_ row: ListRow, in section: Int) -> Bool {
            moved.contains(row.id) && row.item.parent?.id == task && !(section == target && row.under?.id == task)
        }
        var result = sections
        var blocks: [[ListRow]] = []
        var taken = Set<UUID>()
        for index in result.indices {
            let rows = result[index]
            var kept: [ListRow] = []
            var position = 0
            while position < rows.count {
                let row = rows[position]
                guard isMoving(row, in: index) else {
                    kept.append(row)
                    position += 1
                    continue
                }
                var end = position + 1
                while end < rows.count, rows[end].depth > row.depth { end += 1 }
                if taken.insert(row.id).inserted { blocks.append(Array(rows[position..<end])) }
                position = end
            }
            result[index] = kept
        }
        guard !blocks.isEmpty, let at = result[target].firstIndex(where: { $0.id == task }) else { return sections }
        let taskRow = result[target][at]
        var end = at + 1
        while end < result[target].count, result[target][end].depth > taskRow.depth { end += 1 }
        let nested = blocks.flatMap { block in
            let shift = taskRow.depth + 1 - block[0].depth
            return block.enumerated().map { offset, row in
                ListRow(item: row.item, depth: row.depth + shift, under: offset == 0 ? taskRow.item : row.under)
            }
        }
        result[target].insert(contentsOf: nested, at: end)
        return result
    }
}

extension ListRow: Equatable {
    /// Rows are equal when they show the same item at the same place.
    public static func == (a: ListRow, b: ListRow) -> Bool {
        a.item.id == b.item.id && a.depth == b.depth && a.under?.id == b.under?.id
    }
}

extension Item {
    /// The order of a list: the order items were put in, with the newest first among those never
    /// moved.
    public static func inListOrder(_ a: Item, _ b: Item) -> Bool {
        a.sortOrder != b.sortOrder ? a.sortOrder < b.sortOrder : a.createdAt > b.createdAt
    }
}

extension ListRow {
    /// The item that rows dropped before `rows[index]`, or at the end when `index` is the count,
    /// go before among the list's items: the next row that isn't a sub-item. Nil for the end.
    public static func nextItem(in rows: [ListRow], at index: Int) -> Item? {
        rows[index...].first { !$0.isSubItem }?.item
    }

    /// `items` as rows: each nested under the nearest task it's a subtask of that's among them,
    /// in its subtasks' order, and the rest in the order given. Only the rows at the top that
    /// `keepingTop` admits are kept, each with everything nested under it, whatever it is.
    public static func rows(_ items: [Item], doneSince: Date?, keepingTop: (Item) -> Bool = { _ in true }) -> [ListRow] {
        let ids = Set(items.map(\.id))
        var nested: [UUID: [Item]] = [:]
        var top: [Item] = []
        for item in items {
            if let shown = item.ancestors.first(where: { ids.contains($0.id) }) {
                nested[shown.id, default: []].append(item)
            } else {
                top.append(item)
            }
        }
        func rows(_ item: Item, under parent: Item?, depth: Int) -> [ListRow] {
            let row = ListRow(item: item, depth: depth, under: parent)
            let under = (nested[item.id] ?? []).sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
            return [row] + under.flatMap { rows($0, under: item, depth: depth + 1) }
        }
        return top.filter(keepingTop).flatMap { rows($0, under: nil, depth: 0) }
    }
}

extension Item {
    /// How many of its sub-items are done, of how many, leaving out those in the trash or
    /// dropped. Nil when it has none.
    public var subItemCount: (done: Int, total: Int)? {
        let subItems = (children ?? []).filter { $0.bucket != .trash && $0.status != .dropped }
        guard !subItems.isEmpty else { return nil }
        return (subItems.count { $0.status == .done }, subItems.count)
    }
}

extension Item {
    /// Numbers `items` in their order, setting `modifiedAt` on those whose place changes.
    public static func putInOrder(_ items: [Item], at now: Date = .now) {
        for (index, item) in items.enumerated() where item.sortOrder != Double(index) {
            item.sortOrder = Double(index)
            item.modifiedAt = now
        }
    }
}

extension Area {
    /// `values` grouped by their area, in the areas' order with no area last, each group in the
    /// order `values` has it.
    static func group<T>(_ values: [T], by area: (T) -> Area?) -> [(area: Area?, values: [T])] {
        var byArea: [UUID: (area: Area, values: [T])] = [:]
        var none: [T] = []
        for value in values {
            if let area = area(value) {
                byArea[area.id, default: (area, [])].values.append(value)
            } else {
                none.append(value)
            }
        }
        let groups: [(area: Area?, values: [T])] = byArea.values
            .sorted { ($0.area.sortOrder, $0.area.name, $0.area.id.uuidString) < ($1.area.sortOrder, $1.area.name, $1.area.id.uuidString) }
            .map { ($0.area, $0.values) }
        return none.isEmpty ? groups : groups + [(nil, none)]
    }
}
