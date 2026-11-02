import Foundation
import SwiftData

/// A detail an item can be given in its row, in the order rows show them: where it belongs, when,
/// doing it, then waiting, as `ItemField.Group` has them.
public enum ItemField: String, CaseIterable, Sendable {
    case area
    case project
    case scheduled
    case due
    case repeats
    case hideUntil
    case meeting
    case contexts
    case timeEstimate
    case energy
    case waitingFor
    case followUp
}

extension ItemField {
    /// The details that belong together, in the inspector's order.
    public enum Group: CaseIterable, Sendable {
        case belongs
        case when
        case doing
        case waiting

        /// The group's details, in the rows' order.
        public var fields: [ItemField] { ItemField.allCases.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .area, .project: .belongs
        case .scheduled, .due, .hideUntil, .repeats, .meeting: .when
        case .contexts, .timeEstimate, .energy: .doing
        case .waitingFor, .followUp: .waiting
        }
    }

    /// The details that make sense for items in `bucket`: who it's waiting for and when to follow
    /// up only in Waiting, a day to do it only for things still to be done, and how long it takes
    /// and the energy it needs only for actions, for choosing what to do. Anything out of the trash
    /// can be hidden until a day, and anything still to be done can repeat. Only a note in
    /// Reference is for a meeting.
    public static func fields(for bucket: Bucket) -> [ItemField] {
        switch bucket {
        case .inbox: [.area, .project, .scheduled, .due, .repeats, .hideUntil, .contexts]
        case .action: [.area, .project, .scheduled, .due, .repeats, .hideUntil, .contexts, .timeEstimate, .energy]
        case .waiting: [.area, .project, .due, .repeats, .hideUntil, .waitingFor, .followUp]
        case .someday: [.area, .project, .hideUntil]
        case .reference: [.area, .project, .hideUntil, .meeting]
        case .trash: []
        }
    }

}

extension Item {
    /// How many levels of subtasks an item can have under it.
    public static let deepestSubItem = 8

    /// Whether it has subtasks, leaving out those in the trash or dropped: a project.
    public var isProject: Bool { (children ?? []).contains { $0.bucket != .trash && $0.status != .dropped } }

    /// The task it's a subtask of, shown as its Project tag.
    public var project: Item? { parent }

    /// How many tasks it's under: 0 at the top.
    public var depth: Int { ancestors.count }

    /// How many levels of sub-items it has under it: 0 with none.
    public var subItemLevels: Int { (children ?? []).map { $0.subItemLevels + 1 }.max() ?? 0 }

    /// Its sub-items at every level, each before its own.
    public var descendants: [Item] { (children ?? []).flatMap { [$0] + $0.descendants } }

    /// The items it's under, nearest first.
    public var ancestors: [Item] { parent.map { [$0] + $0.ancestors } ?? [] }

    /// The details that make sense for the item where it is.
    public var editableFields: [ItemField] { ItemField.fields(for: bucket) }

    /// The details the inspector offers: every one, wherever the item is, so it can be given any
    /// of them before it's moved, except the meeting, only for items in Reference. An item in the
    /// trash has those of the list Put Back returns it to.
    public var inspectableFields: [ItemField] {
        let list = bucket == .trash ? TrashList.destination(of: self) : bucket
        return ItemField.allCases.filter { $0 != .meeting || list == .reference }
    }

    /// Marks the item done, with its open sub-items at every level.
    public func markDone(at now: Date = .now) {
        guard status != .done else { return }
        for subItem in descendants where subItem.status == .open {
            subItem.status = .done
            subItem.completedAt = now
            subItem.modifiedAt = now
        }
        status = .done
        completedAt = now
        modifiedAt = now
    }

    /// Opens a done item again, with the sub-items at every level that were done along with it. A
    /// sub-item opens every item it's under too.
    public func reopen(at now: Date = .now) {
        guard status == .done else { return }
        for subItem in descendants where subItem.status == .done && subItem.completedAt == completedAt {
            subItem.status = .open
            subItem.completedAt = nil
            subItem.modifiedAt = now
        }
        status = .open
        completedAt = nil
        modifiedAt = now
        for parent in ancestors where parent.status == .done {
            parent.status = .open
            parent.completedAt = nil
            parent.modifiedAt = now
        }
    }

    /// The day in a date field: `due`, `scheduled`, `hideUntil` or `followUp`. Nil for other
    /// fields.
    public func day(_ field: ItemField) -> LocalDate? {
        switch field {
        case .due: dueDate.map(LocalDate.init(day:))
        case .hideUntil: hideUntil.map(LocalDate.init(day:))
        case .scheduled: scheduledDate.map(LocalDate.init(day:))
        case .followUp: followUpDate.map(LocalDate.init(day:))
        default: nil
        }
    }

    // Each setter changes `modifiedAt` only when the value changes.

    public func setTitle(_ title: String, at now: Date = .now) {
        guard title != self.title else { return }
        self.title = title
        modifiedAt = now
    }

    public func setTimeEstimate(_ estimate: TimeEstimate?, at now: Date = .now) {
        guard estimate != timeEstimate else { return }
        timeEstimate = estimate
        modifiedAt = now
    }

    public func setEnergy(_ energy: Energy?, at now: Date = .now) {
        guard energy != self.energy else { return }
        self.energy = energy
        modifiedAt = now
    }

    /// Sets or clears the day in a date field: `due`, `scheduled`, `hideUntil` or `followUp`.
    /// Moving a repeating copy's date moves this copy only: the repeat keeps the days it took from
    /// the old date (`RepeatRule.pinned(to:)`).
    public func setDay(_ day: LocalDate?, for field: ItemField, at now: Date = .now) {
        let stored = day?.storedDate
        if (field == .scheduled && stored != scheduledDate) || (field == .due && scheduledDate == nil && stored != dueDate) { pinRepeat(at: now) }
        switch field {
        case .due:
            guard stored != dueDate else { return }
            dueDate = stored
        case .scheduled:
            guard stored != scheduledDate else { return }
            scheduledDate = stored
        case .followUp:
            guard stored != followUpDate else { return }
            followUpDate = stored
        case .hideUntil:
            guard stored != hideUntil else { return }
            hideUntil = stored
        default: return
        }
        modifiedAt = now
    }

    /// An open action in the Inbox or Actions, which can be given a start date.
    public var canStart: Bool {
        status == .open && kind == .action && (bucket == .inbox || bucket == .action)
    }

    /// Starts the item on `day`, keeping its time of day, in `calendar`'s time zone. An Inbox
    /// item moves to Actions, and an item hidden until after `day` is shown.
    public func start(on day: LocalDate, in calendar: Calendar, at now: Date = .now) {
        guard canStart else { return }
        if day != self.day(.scheduled) { pinRepeat(at: now) }
        let before = (bucketRaw, scheduledDate, scheduledTime, hideUntil)
        bucket = .action
        if let time = scheduledTime {
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            scheduledTime = day.date(in: calendar, hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
        scheduledDate = day.storedDate
        if let hidden = hideUntil, LocalDate(day: hidden) > day { hideUntil = nil }
        if before != (bucketRaw, scheduledDate, scheduledTime, hideUntil) { modifiedAt = now }
    }

    /// Makes the item a subtask of `project`, or of none. It stays where it is when it can't go
    /// there (`Clarifier.canMake(_:aSubItemOf:)`).
    public func setProject(_ project: Item?, at now: Date = .now) {
        guard project?.id != parent?.id, project.map({ Clarifier.canMake(self, aSubItemOf: $0) }) ?? true else { return }
        parent = project
        modifiedAt = now
    }

    /// Links it to the calendar event series with `id`, or with nil unlinks it.
    public func setCalendarEvent(_ id: String?, at now: Date = .now) {
        guard id != calendarEventID else { return }
        calendarEventID = id
        modifiedAt = now
    }

    public func setSequential(_ isSequential: Bool, at now: Date = .now) {
        guard isSequential != self.isSequential else { return }
        self.isSequential = isSequential
        modifiedAt = now
    }

    public func setArea(_ area: Area?, at now: Date = .now) {
        guard area?.id != self.area?.id else { return }
        self.area = area
        modifiedAt = now
    }

    /// Adds the context, or removes it if the item has it.
    public func toggle(_ context: Context, at now: Date = .now) {
        var contexts = self.contexts ?? []
        if let index = contexts.firstIndex(where: { $0.id == context.id }) {
            contexts.remove(at: index)
        } else {
            contexts.append(context)
        }
        self.contexts = contexts
        modifiedAt = now
    }

    /// Sets who the item is waiting for; blank text clears it.
    public func setWaitingFor(_ person: String, at now: Date = .now) {
        let trimmed = person.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        guard value != waitingOn else { return }
        waitingOn = value
        modifiedAt = now
    }
}

/// Makes the areas and contexts chosen for an item while it's edited, and new items and subtasks.
/// Areas and contexts are put after the others of their kind; a blank name makes nothing.
public enum NewRecord {
    public static func area(named name: String, in context: ModelContext) -> Area? {
        guard let name = trimmed(name) else { return nil }
        let made = Area(name: name)
        made.sortOrder = next(Area.self, \.sortOrder, in: context)
        context.insert(made)
        return made
    }

    public static func context(named name: String, in context: ModelContext) -> Context? {
        guard let name = trimmed(name) else { return nil }
        let made = Context(name: name)
        made.sortOrder = next(Context.self, \.sortOrder, in: context)
        context.insert(made)
        return made
    }

    /// An item with no title yet, in `bucket` and the area with the `area` ID, on the `scheduled`
    /// day if one's given.
    public static func item(in bucket: Bucket, scheduled: LocalDate? = nil, area: UUID? = nil, in context: ModelContext) -> Item {
        let made = Item(title: "", bucket: bucket)
        made.sortOrder = topOrder(in: context)
        made.scheduledDate = scheduled?.storedDate
        made.area = area.flatMap { id in try? context.fetch(FetchDescriptor<Area>(predicate: #Predicate { $0.id == id })).first }
        context.insert(made)
        return made
    }

    /// An untitled subtask at the end of `parent`'s, with a copy of its bucket, area, contexts,
    /// start day and time, due date, time and energy, and who it's waiting for with the follow-up
    /// date. Under an item in Reference it's an action. Nil when `parent` is in
    /// the trash or as deep as subtasks go.
    public static func subtask(of parent: Item, in context: ModelContext) -> Item? {
        guard parent.bucket != .trash, parent.depth < Item.deepestSubItem else { return nil }
        let made = Item(title: "", bucket: parent.bucket == .reference ? .action : parent.bucket)
        made.sortOrder = ((parent.children ?? []).map(\.sortOrder).max()).map { $0 + 1 } ?? 0
        made.scheduledDate = parent.scheduledDate
        made.scheduledTime = parent.scheduledTime
        made.dueDate = parent.dueDate
        made.timeEstimateRaw = parent.timeEstimateRaw
        made.energyRaw = parent.energyRaw
        made.waitingOn = parent.waitingOn
        made.followUpDate = parent.followUpDate
        context.insert(made)
        made.area = parent.area
        made.contexts = parent.contexts
        made.parent = parent
        return made
    }

    /// The order that puts a new item above every other.
    public static func topOrder(in context: ModelContext) -> Double {
        ((try? context.fetch(FetchDescriptor<Item>()))?.map(\.sortOrder).min() ?? 1) - 1
    }

    private static func trimmed(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func next<T: PersistentModel>(_ type: T.Type, _ order: KeyPath<T, Double>, in context: ModelContext) -> Double {
        ((try? context.fetch(FetchDescriptor<T>()))?.map { $0[keyPath: order] }.max()).map { $0 + 1 } ?? 0
    }
}

extension Item {
    /// The day a repeat's next copy counts from: the scheduled day, or else the due day.
    public var repeatBase: LocalDate? { day(.scheduled) ?? day(.due) }

    /// Writes into the item's repeat the days it takes from the item's date, before that date
    /// moves.
    func pinRepeat(at now: Date) {
        guard let repetition = repeatRule, let rule = repetition.rule, let base = repeatBase else { return }
        let pinned = rule.pinned(to: base)
        guard pinned != rule else { return }
        repetition.rule = pinned
        repetition.modifiedAt = now
    }
}
