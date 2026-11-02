import Foundation

/// What a list's selection becomes as its rows change.
public enum ListSelection {
    /// The selection once a list's rows go from `before` to `now`: the selected rows still there;
    /// or, when none of them are, the row that came after the last of them, or else the one
    /// before the first, as Mail selects the next message once one is filed.
    public static func kept<ID: Hashable>(_ selected: Set<ID>, before: [ID], now: [ID]) -> Set<ID> {
        let remaining = Set(now)
        let still = selected.intersection(remaining)
        guard still.isEmpty, !selected.isEmpty else { return still }
        let places = before.indices.filter { selected.contains(before[$0]) }
        guard let first = places.first, let last = places.last else { return [] }
        if let after = before[(last + 1)...].first(where: remaining.contains) { return [after] }
        if let earlier = before[..<first].last(where: remaining.contains) { return [earlier] }
        return []
    }
}
