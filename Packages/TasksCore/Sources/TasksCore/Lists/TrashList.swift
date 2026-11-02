import Foundation
import SwiftData

/// The Trash: what's been moved to it, put back where it came from, and
/// deleted when it's emptied or 30 days after it was trashed.
public enum TrashList {
    /// How long an item stays in the trash.
    public static let keptFor: TimeInterval = 30 * 86400

    /// What's in the trash, most recently trashed first, then the subtasks of each, at every
    /// level, for its rows to nest under it. Dropped subtasks are left out.
    public static func items(_ items: [Item]) -> [Item] {
        let trashed = items.filter { $0.bucket == .trash }.sorted { trashed($0) > trashed($1) }
        let ids = Set(trashed.map(\.id))
        return trashed + trashed.flatMap(\Item.descendants).filter { !ids.contains($0.id) && $0.status != .dropped }
    }

    /// When the item was trashed: for one trashed before that was kept, when it last changed.
    public static func trashed(_ item: Item) -> Date {
        item.trashedAt ?? item.modifiedAt
    }

    /// Where Put Back returns the item: the list it was trashed from, or the Inbox when that isn't
    /// known.
    public static func destination(of item: Item) -> Bucket {
        item.trashedFrom.flatMap { $0 == .trash ? nil : $0 } ?? .inbox
    }

    /// Puts the item back where `destination(of:)` says, with its subtasks.
    public static func putBack(_ item: Item, at now: Date = .now) {
        guard item.bucket == .trash else { return }
        item.bucket = destination(of: item)
        item.trashedFrom = nil
        item.trashedAt = nil
        item.modifiedAt = now
    }

    /// Deletes everything in the trash, with its subtasks. The number of items deleted from it.
    @MainActor
    @discardableResult
    public static func empty(in context: ModelContext) -> Int {
        delete(in: context) { _ in true }
    }

    /// Deletes what was trashed more than `keptFor` before `now`, with its subtasks. The number
    /// of items deleted from the trash.
    @MainActor
    @discardableResult
    public static func deleteOld(in context: ModelContext, at now: Date = .now) -> Int {
        delete(in: context) { trashed($0) < now.addingTimeInterval(-keptFor) }
    }

    @MainActor
    private static func delete(in context: ModelContext, where expired: (Item) -> Bool) -> Int {
        let trash = Bucket.trash.rawValue
        let trashed = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.bucketRaw == trash }))) ?? []
        let deleting = trashed.filter(expired)
        for item in deleting { context.delete(item) }
        return deleting.count
    }
}
