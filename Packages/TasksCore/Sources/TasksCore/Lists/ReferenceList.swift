import Foundation

/// Reference's items in one area and project.
public struct ReferenceGroup: Identifiable {
    /// Nil for those in no area.
    public let area: Area?
    /// Nil for those in no project.
    public let project: Item?
    public let items: [Item]

    public var id: String { "\(area.map { "area-\($0.id)" } ?? "no-area")/\(project.map { "project-\($0.id)" } ?? "no-project")" }
}

public enum ReferenceList {
    /// Reference on `today`: items filed in Reference, and notes among the
    /// actions, open or done since `doneSince` and not hidden. They're grouped by area, in the
    /// areas' order with no area last, then by project, those in no project first and then the
    /// projects in their order. An item is in its own area, or its project's when it has none.
    /// Each group is in the list's order.
    public static func groups(_ items: [Item], today: LocalDate, doneSince: Date?, showsHidden: Bool = false) -> [ReferenceGroup] {
        let shown = items.filter {
            ($0.bucket == .reference || ($0.bucket == .action && $0.kind == .note))
                && $0.isListed(today: today, doneSince: doneSince, showsHidden: showsHidden)
        }
        .sorted(by: Item.inListOrder)
        return Area.group(shown) { $0.area ?? $0.project?.area }.flatMap { area, items in
            var byProject: [UUID: (project: Item, items: [Item])] = [:]
            var none: [Item] = []
            for item in items {
                if let project = item.project {
                    byProject[project.id, default: (project, [])].items.append(item)
                } else {
                    none.append(item)
                }
            }
            let projects = byProject.values
                .sorted { Item.inListOrder($0.project, $1.project) }
                .map { ReferenceGroup(area: area, project: $0.project, items: $0.items) }
            return none.isEmpty ? projects : [ReferenceGroup(area: area, project: nil, items: none)] + projects
        }
    }
}
