import Foundation
import SwiftData

/// Adds captured text to the Inbox: one item per line, with what its tokens name.
public enum Capture {
    /// The projects and contexts in the store, for the parser to recognise.
    public static func vocabulary(in context: ModelContext) -> CaptureVocabulary {
        let contexts = (try? context.fetch(FetchDescriptor<Context>())) ?? []
        return CaptureVocabulary(
            projects: openProjects(in: context).map(\.title),
            contexts: contexts.filter { !$0.isHidden }.map(\.name))
    }

    /// The open tasks with subtasks, in Actions, on Someday or in Reference, which captures can be put under.
    public static func openProjects(in context: ModelContext) -> [Item] {
        let open = ItemStatus.open.rawValue
        let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.statusRaw == open }))) ?? []
        return items.filter { $0.isOpenProject && [.action, .someday, .reference].contains($0.bucket) }
    }

    /// Parses `text` and inserts its items into `context`, in `bucket` (the Inbox unless it's
    /// given) and in the area with the `area` ID if there is one, without saving. `scheduled` is
    /// the day for items whose text doesn't give one.
    @discardableResult
    public static func add(
        _ text: String, source: ItemSource, today: LocalDate, area: UUID? = nil, bucket: Bucket = .inbox, scheduled: LocalDate? = nil,
        in context: ModelContext
    ) -> [Item] {
        let drafts = CaptureParser.parse(text, today: today, vocabulary: vocabulary(in: context))
        let projects = openProjects(in: context)
        let contexts = (try? context.fetch(FetchDescriptor<Context>())) ?? []
        let area = area.flatMap { id in try? context.fetch(FetchDescriptor<Area>(predicate: #Predicate { $0.id == id })).first }
        let base = Date.now
        let top = NewRecord.topOrder(in: context)
        return drafts.enumerated().map { index, draft in
            let item = Item(title: draft.title, bucket: bucket)
            item.createdAt = base.addingTimeInterval(Double(index) * 0.001)
            // At the top of their list, in the order the lines were written.
            item.sortOrder = top - Double(drafts.count - 1 - index)
            item.modifiedAt = item.createdAt
            item.source = source
            item.dueDate = draft.dueDate?.storedDate
            item.scheduledDate = (draft.scheduledDate ?? scheduled)?.storedDate
            context.insert(item)
            item.area = area
            item.parent = draft.project.flatMap { name in projects.first { $0.title == name } }
            item.contexts = draft.contexts.compactMap { name in contexts.first { $0.name == name } }
            if let rule = draft.repeatRule {
                let repetition = Repetition()
                repetition.rule = rule
                repetition.naturalText = draft.repeatText ?? ""
                context.insert(repetition)
                item.repeatRule = repetition
            }
            return item
        }
    }
}

/// A detail of quick entry's item: left to its first line's tokens, or the list's area for the
/// area, or chosen, as none or as a value.
public enum CaptureChoice<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchosen
    case chosen(Value?)

    /// The value chosen, or else `otherwise`.
    public func or(_ otherwise: Value?) -> Value? {
        switch self {
        case .unchosen: otherwise
        case .chosen(let value): value
        }
    }
}

/// What quick entry chooses for its item besides its text. A detail chosen here, as none or as a
/// value, wins over the one its first line's tokens name.
public struct CaptureDetails: Equatable, Sendable {
    public var area: CaptureChoice<UUID> = .unchosen
    public var project: CaptureChoice<UUID> = .unchosen
    public var scheduled: CaptureChoice<LocalDate> = .unchosen
    public var due: CaptureChoice<LocalDate> = .unchosen
    /// An `every …` phrase, such as "every 2 weeks".
    public var repeats: CaptureChoice<String> = .unchosen
    public var contexts: CaptureChoice<[UUID]> = .unchosen
    public var timeEstimate: TimeEstimate?
    public var energy: Energy?

    public init() {}
}

extension Capture {
    /// Quick entry's text as an item: its first line with something in it, and what that line's
    /// tokens name, and the lines after it as notes, without blank lines at either end.
    public static func entry(_ text: String, today: LocalDate, vocabulary: CaptureVocabulary) -> (draft: CaptureDraft, notes: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let first = lines.first else { return (CaptureDraft(title: ""), "") }
        var rest = Array(lines.dropFirst())
        while let line = rest.first, line.trimmingCharacters(in: .whitespaces).isEmpty { rest.removeFirst() }
        while let line = rest.last, line.trimmingCharacters(in: .whitespaces).isEmpty { rest.removeLast() }
        let draft = CaptureParser.parseLine(first.trimmingCharacters(in: .whitespaces), today: today, vocabulary: vocabulary)
        return (draft, rest.joined(separator: "\n"))
    }

    /// Inserts quick entry's item into the Inbox in `context`, at its top, without saving: its
    /// first line the title and the rest its notes, with `details` and what the first line's
    /// tokens name, and in the area with the `area` ID unless another's chosen. Nil when the first
    /// line has no title.
    @discardableResult
    public static func add(
        entry text: String, details: CaptureDetails, area: UUID? = nil, source: ItemSource, today: LocalDate, in context: ModelContext
    ) -> Item? {
        let (draft, notes) = entry(text, today: today, vocabulary: vocabulary(in: context))
        guard !draft.title.isEmpty else { return nil }
        let item = Item(title: draft.title, bucket: .inbox)
        item.body = notes
        item.sortOrder = NewRecord.topOrder(in: context)
        item.source = source
        item.dueDate = details.due.or(draft.dueDate)?.storedDate
        item.scheduledDate = details.scheduled.or(draft.scheduledDate)?.storedDate
        item.timeEstimate = details.timeEstimate
        item.energy = details.energy
        context.insert(item)
        if let id = details.area.or(area) {
            item.area = try? context.fetch(FetchDescriptor<Area>(predicate: #Predicate { $0.id == id })).first
        }
        let projects = openProjects(in: context)
        switch details.project {
        case .unchosen: item.parent = draft.project.flatMap { name in projects.first { $0.title == name } }
        case .chosen(let id): item.parent = id.flatMap { id in projects.first { $0.id == id } }
        }
        let contexts = (try? context.fetch(FetchDescriptor<Context>())) ?? []
        switch details.contexts {
        case .unchosen: item.contexts = draft.contexts.compactMap { name in contexts.first { $0.name == name } }
        case .chosen(let ids): item.contexts = (ids ?? []).compactMap { id in contexts.first { $0.id == id } }
        }
        if let repeatText = details.repeats.or(draft.repeatText), let rule = CaptureParser.repeatRule(repeatText, today: today) {
            let repetition = Repetition()
            repetition.rule = rule
            repetition.naturalText = repeatText
            context.insert(repetition)
            item.repeatRule = repetition
        }
        return item
    }
}
