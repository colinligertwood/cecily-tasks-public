import Foundation

/// Someday's items and projects in one area.
public struct SomedayGroup: Identifiable {
    /// Nil for those in no area.
    public let area: Area?
    public let items: [Item]

    public var id: String { area.map { "area-\($0.id)" } ?? "no-area" }
}

public enum SomedayList {
    /// Someday on `today`: its items and projects, open or done since
    /// `doneSince`, not hidden and not in a project that's done or gone, grouped by area in the
    /// areas' order with no area last. An item is in its own area, or its project's when it has
    /// none. Each group is in the list's order.
    public static func groups(_ items: [Item], today: LocalDate, doneSince: Date?, showsHidden: Bool = false) -> [SomedayGroup] {
        let shown = items.filter {
            $0.bucket == .someday && $0.isListed(today: today, doneSince: doneSince, showsHidden: showsHidden)
                && $0.project.map { $0.status == .open } ?? true
        }
        .sorted(by: Item.inListOrder)
        return Area.group(shown) { $0.area ?? $0.project?.area }.map { SomedayGroup(area: $0.area, items: $0.values) }
    }
}

extension Clarifier {
    /// Moves Someday's items to Actions, keeping their project, and makes Someday's projects
    /// active, with the project of each item that's on Someday too.
    public static func activate(_ items: [Item], at now: Date = .now) -> Undo? {
        let chosen = items.filter { $0.bucket == .someday }
        guard !chosen.isEmpty else { return nil }
        let projects = chosen.compactMap(\.project).filter { project in project.bucket == .someday && !chosen.contains { $0 === project } }
        let moving =
            chosen
            + projects.reduce(into: [Item]()) { unique, project in
                if !unique.contains(where: { $0 === project }) { unique.append(project) }
            }
        let undo = Undo(moving, title: chosen.count == 1 ? chosen[0].title : "\(chosen.count) items")
        for item in moving {
            item.bucket = .action
            item.modifiedAt = now
        }
        return undo
    }
}
