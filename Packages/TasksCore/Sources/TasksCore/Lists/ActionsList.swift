import Foundation

/// How Actions groups its items.
public enum ActionsGrouping: String, CaseIterable, Sendable {
    case context
    case project
    case area
    case none
}

/// What narrows Actions: the most time an action may take, the most energy it may need, and
/// whether it's due within a week. An action without an estimate or energy is left out by that
/// filter.
public struct ActionsFilter: Hashable, Sendable {
    public var time: TimeEstimate?
    public var energy: Energy?
    public var dueSoon = false

    /// The days ahead "due soon" reaches.
    public static let dueSoonDays = 7

    public init(time: TimeEstimate? = nil, energy: Energy? = nil, dueSoon: Bool = false) {
        self.time = time
        self.energy = energy
        self.dueSoon = dueSoon
    }

    public var isEmpty: Bool { time == nil && energy == nil && !dueSoon }

    public func admits(_ item: Item, today: LocalDate) -> Bool {
        if let time {
            guard let estimate = item.timeEstimate, estimate.rank <= time.rank else { return false }
        }
        if let energy {
            guard let needed = item.energy, needed.rank <= energy.rank else { return false }
        }
        if dueSoon {
            guard let due = item.dueDate.map(LocalDate.init(day:)), due <= today.adding(days: Self.dueSoonDays) else { return false }
        }
        return true
    }
}

extension TimeEstimate {
    fileprivate var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

extension Energy {
    fileprivate var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A group of a list's items under one heading.
public struct ListGroup: Identifiable {
    public enum Heading {
        case context(Context)
        case project(Item)
        case area(Area)
        case noContext
        case noProject
        case noArea
        /// The list isn't grouped.
        case all
    }

    public let heading: Heading
    public let items: [Item]

    public var id: String {
        switch heading {
        case .context(let context): "context-\(context.id)"
        case .project(let project): "project-\(project.id)"
        case .area(let area): "area-\(area.id)"
        case .noContext: "no-context"
        case .noProject: "no-project"
        case .noArea: "no-area"
        case .all: "all"
        }
    }
}

public enum ActionsList {
    /// The items in Actions on `today` that `filter` admits, in their order, in groups: by context
    /// in the contexts' order with an action in each of its contexts, by project, by area (its
    /// own or its project's), or in one group. Hidden contexts don't count. Items without one come
    /// last, and empty groups are left out. Items in `keeping` stay as though still in Actions,
    /// such as a task whose rows are settling under it.
    public static func groups(
        _ items: [Item], by grouping: ActionsGrouping, filter: ActionsFilter = ActionsFilter(), today: LocalDate, doneSince: Date?,
        showsHidden: Bool = false, keeping: Set<UUID> = []
    ) -> [ListGroup] {
        let shown = items.filter {
            ($0.isInActions(today: today, doneSince: doneSince, showsHidden: showsHidden) || keeping.contains($0.id))
                && filter.admits($0, today: today)
        }
        .sorted(by: Item.inListOrder)
        switch grouping {
        case .context:
            return grouped(shown, none: .noContext) { item in
                (item.contexts ?? []).filter { !$0.isHidden }.map { Key($0.id, ($0.sortOrder, $0.name), .context($0)) }
            }
        case .project:
            return grouped(shown, none: .noProject) { item in
                item.project.map { [Key($0.id, ($0.sortOrder, $0.title), .project($0))] } ?? []
            }
        case .area:
            return grouped(shown, none: .noArea) { item in
                (item.area ?? item.project?.area).map { [Key($0.id, ($0.sortOrder, $0.name), .area($0))] } ?? []
            }
        case .none:
            return shown.isEmpty ? [] : [ListGroup(heading: .all, items: shown)]
        }
    }

    /// The days an action goes unchanged before the weekly review shows it.
    public static let unchangedDays = 14

    /// The items in Actions on `today` not changed in the last `unchangedDays` days, the one
    /// changed longest ago first, for the weekly review. Days start at `boundary`.
    public static func unchanged(
        _ items: [Item], today: LocalDate, boundary: DayBoundary, in calendar: Calendar, doneSince: Date?, showsHidden: Bool = false
    ) -> [Item] {
        let since = boundary.start(of: today.adding(days: 1 - unchangedDays), in: calendar)
        return items.filter { $0.modifiedAt < since && $0.isInActions(today: today, doneSince: doneSince, showsHidden: showsHidden) }
            .sorted { ($0.modifiedAt, $0.id.uuidString) < ($1.modifiedAt, $1.id.uuidString) }
    }

    /// Whole days since the item was last changed, by days that start at `boundary`.
    public static func daysUnchanged(_ item: Item, today: LocalDate, boundary: DayBoundary, in calendar: Calendar) -> Int {
        boundary.day(at: item.modifiedAt, in: calendar).days(to: today)
    }

    private struct Key {
        let id: UUID
        let order: (Double, String)
        let heading: ListGroup.Heading

        init(_ id: UUID, _ order: (Double, String), _ heading: ListGroup.Heading) {
            self.id = id
            self.order = order
            self.heading = heading
        }
    }

    private static func grouped(_ items: [Item], none: ListGroup.Heading, keys: (Item) -> [Key]) -> [ListGroup] {
        var found: [UUID: (key: Key, items: [Item])] = [:]
        var rest: [Item] = []
        for item in items {
            let itemKeys = keys(item)
            if itemKeys.isEmpty { rest.append(item) }
            for key in itemKeys { found[key.id, default: (key, [])].items.append(item) }
        }
        let groups = found.values
            .sorted { ($0.key.order.0, $0.key.order.1, $0.key.id.uuidString) < ($1.key.order.0, $1.key.order.1, $1.key.id.uuidString) }
            .map { ListGroup(heading: $0.key.heading, items: $0.items) }
        return rest.isEmpty ? groups : groups + [ListGroup(heading: none, items: rest)]
    }
}
