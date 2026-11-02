import Foundation
import SwiftData

/// Files an item where a `ClarifyOutcome` says, and remembers how it was so the decision can be
/// undone.
public enum Clarifier {
    /// How things were before one decision: the fields of each record it changed, the first the
    /// one it was about, and what it made (a new task, more subtasks, a repeat), to be deleted
    /// again.
    public struct Undo: Sendable {
        let before: [(id: RecordID, fields: [String: SyncValue])]
        let made: [RecordID]
        /// The title before, of the item or project it was about, for saying what's undone.
        public let title: String

        init(before: [(id: RecordID, fields: [String: SyncValue])], made: [RecordID] = [], title: String) {
            self.before = before
            self.made = made
            self.title = title
        }

        /// How `records` are now, the first the one the decision is about.
        public init(_ records: [any SyncModel], made: [RecordID] = [], title: String) {
            self.init(before: records.map { ($0.recordID, $0.syncFields()) }, made: made, title: title)
        }

        /// How the records this undo would put back are now, to put them back to after it's undone.
        /// Nil when the decision made records, which undoing deletes, or one of them has gone.
        @MainActor
        public func current(in context: ModelContext) -> Undo? {
            guard made.isEmpty else { return nil }
            let records = before.compactMap { Clarifier.find($0.id, in: context) }
            guard records.count == before.count else { return nil }
            return Undo(records, title: title)
        }
    }

    /// Applies the outcome to `item` in its context, without saving.
    @MainActor
    @discardableResult
    public static func file(_ item: Item, _ outcome: ClarifyOutcome, today: LocalDate, calendar: Calendar = .current) -> Undo {
        guard let context = item.modelContext else { preconditionFailure("The item isn't in a context") }
        let records: [any SyncModel] = [item] + [item.repeatRule].compactMap { $0 }
        let undo = Undo(records, title: item.title)
        var made: [RecordID] = []
        let now = Date.now

        if let title = outcome.title, !title.isEmpty { item.title = title }
        switch outcome.project {
        case .existing(let id):
            item.setProject(try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first, at: now)
        case .new(let title, let moreActions):
            let project = Item(title: title, bucket: .action)
            project.sortOrder = NewRecord.topOrder(in: context)
            context.insert(project)
            made.append(project.recordID)
            item.parent = project
            for (index, action) in moreActions.enumerated() where !action.trimmingCharacters(in: .whitespaces).isEmpty {
                let next = Item(title: action.trimmingCharacters(in: .whitespaces), bucket: .action)
                next.source = item.source
                next.sortOrder = Double(index + 1)
                context.insert(next)
                next.parent = project
                made.append(next.recordID)
            }
        case nil:
            break
        }

        if item.bucket == .trash, outcome.destination != .trash {
            item.trashedAt = nil
            item.trashedFrom = nil
        }
        switch outcome.destination {
        case .trash:
            if item.bucket != .trash {
                item.trashedFrom = item.bucket
                item.trashedAt = now
            }
            item.bucket = .trash
        case .someday:
            item.bucket = .someday
        case .reference:
            item.bucket = .reference
        case .doneNow:
            item.bucket = .action
            item.status = .done
            item.completedAt = now
        case .waiting(let person, let followUp):
            item.bucket = .waiting
            item.waitingOn = person.isEmpty ? nil : person
            item.followUpDate = followUp?.storedDate
        case .scheduled(let date, let time):
            item.bucket = .action
            item.scheduledDate = date.storedDate
            item.scheduledTime = time.map { date.date(in: calendar, hour: $0 / 60, minute: $0 % 60) }
        case .action:
            item.bucket = .action
        }

        if let ids = outcome.contexts {
            let contexts = (try? context.fetch(FetchDescriptor<Context>())) ?? []
            item.contexts = ids.compactMap { id in contexts.first { $0.id == id } }
        }
        if let estimate = outcome.timeEstimate { item.timeEstimate = estimate }
        if let energy = outcome.energy { item.energy = energy }
        if let due = outcome.dueDate { item.dueDate = due.storedDate }
        if let hide = outcome.hideUntil { item.hideUntil = hide.storedDate }
        if let area = outcome.area {
            item.area = try? context.fetch(FetchDescriptor<Area>(predicate: #Predicate { $0.id == area })).first
        }
        if let rule = outcome.repeatRule {
            if let existing = item.repeatRule {
                existing.rule = rule
                existing.modifiedAt = now
            } else {
                let repetition = Repetition()
                repetition.rule = rule
                context.insert(repetition)
                item.repeatRule = repetition
                made.append(repetition.recordID)
            }
        }
        item.modifiedAt = now
        return Undo(before: undo.before, made: made, title: undo.title)
    }

    /// Puts things back as they were before the decision, without saving. False if what it was
    /// about has gone meanwhile (deleted on another device, say).
    @MainActor
    @discardableResult
    public static func undo(_ undo: Undo, in context: ModelContext) -> Bool {
        let records = undo.before.map { find($0.id, in: context) }
        guard let first = records.first, first != nil else { return false }
        let links = SyncLinks(context: context)
        // Records are put back before what was made is deleted, so deleting a project made by the
        // decision doesn't delete the items it was given.
        for (record, before) in zip(records, undo.before) {
            guard let record else { continue }
            record.apply(ServerRecord(id: before.id, tag: nil, fields: before.fields), links)
            record.modifiedAt = .now
        }
        for made in undo.made {
            switch made.type {
            case Item.recordType: delete(Item.self, made.name, in: context)
            case Repetition.recordType: delete(Repetition.self, made.name, in: context)
            default: break
            }
        }
        return true
    }

    @MainActor
    static func find(_ id: RecordID, in context: ModelContext) -> (any SyncModel)? {
        guard let uuid = UUID(uuidString: id.name) else { return nil }
        switch id.type {
        case Item.recordType: return try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == uuid })).first
        case Repetition.recordType: return try? context.fetch(FetchDescriptor<Repetition>(predicate: #Predicate { $0.id == uuid })).first
        default: return nil
        }
    }

    @MainActor
    private static func delete<T: SyncModel>(_ type: T.Type, _ name: String, in context: ModelContext) {
        guard let id = UUID(uuidString: name), let object = try? context.fetch(FetchDescriptor<T>()).first(where: { $0.id == id }) else { return }
        context.delete(object)
    }
}
