import Foundation
import SwiftData

/// A new item while its title is being typed: where it will go, and the title so far. Nothing is
/// in the store until it's made, and an empty one makes nothing.
public struct NewItemDraft: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        /// At the top of a list: in `bucket`, on the `scheduled` day if there is one, and in the
        /// area with the `area` ID.
        case list(bucket: Bucket, scheduled: LocalDate?, area: UUID?)
        /// At the end of the subtasks of the task with this ID, with a copy of its details.
        case subtask(of: UUID)
    }

    public var place: Place
    public var title: String

    public init(_ place: Place, title: String = "") {
        self.place = place
        self.title = title
    }

    /// A draft for a new subtask of `parent`, or nil when it can't have one: in the Trash, or
    /// as deep as subtasks go.
    public static func subtask(of parent: Item) -> NewItemDraft? {
        guard parent.bucket != .trash, parent.depth < Item.deepestSubItem else { return nil }
        return NewItemDraft(.subtask(of: parent.id))
    }

    /// The title as it's kept: on one line, without spaces at either end.
    public var trimmedTitle: String {
        title.replacing("\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { trimmedTitle.isEmpty }

    /// Makes the item with its title, and the undo that takes it away again. Nil for an empty
    /// title, or for a subtask whose task is gone or can't have one.
    @MainActor
    public func make(in context: ModelContext) -> (item: Item, undo: Clarifier.Undo)? {
        guard !isEmpty else { return nil }
        let made: Item
        switch place {
        case .list(let bucket, let scheduled, let area):
            made = NewRecord.item(in: bucket, scheduled: scheduled, area: area, in: context)
        case .subtask(let id):
            guard let parent = try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first,
                let subtask = NewRecord.subtask(of: parent, in: context)
            else { return nil }
            made = subtask
        }
        made.title = trimmedTitle
        return (made, Clarifier.Undo([made], made: [made.recordID], title: made.title))
    }
}
