import Foundation
import SwiftData

// The data model. It follows CloudKit's rules, so it can sync as it is:
//
// - every property has a default or is optional;
// - every relationship is optional (to-many ones too) and has an inverse;
// - no unique constraints, and no deny delete rules.
//
// Every entity has `id`, `createdAt` and `modifiedAt`. `id` names its sync record, and is kept
// after deletion so sync can tell which record went. Date-only fields (due, scheduled, hide
// until, follow up, end and target dates) hold midnight UTC on their day; see `LocalDate(day:)`.
// Choices are stored as raw strings, with typed accessors.
//
// Once the schema is in CloudKit's production environment, fields and entities can be added but
// never removed or changed.

@Model
public final class Item {
    @Attribute(.preserveValueOnDeletion) public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now

    /// One line of plain text.
    public var title: String = ""
    /// The notes, as Markdown, exactly as typed.
    public var body: String = ""
    public var kindRaw: String = ItemKind.action.rawValue
    public var bucketRaw: String = Bucket.inbox.rawValue
    public var statusRaw: String = ItemStatus.open.rawValue
    public var completedAt: Date?

    /// For items not in a project.
    public var area: Area?
    public var contexts: [Context]? = []

    public var waitingOn: String?
    public var followUpDate: Date?
    public var dueDate: Date?
    public var scheduledDate: Date?
    /// The time of day, when the scheduled item has one.
    public var scheduledTime: Date?
    public var hideUntil: Date?
    public var timeEstimateRaw: String?
    public var energyRaw: String?
    @Relationship(deleteRule: .cascade) public var repeatRule: Repetition?

    /// The project it's in, or the item it's a step of.
    public var parent: Item?
    @Relationship(deleteRule: .cascade, inverse: \Item.parent) public var children: [Item]? = []
    public var sortOrder: Double = 0

    public var sourceRaw: String = ItemSource.quickAdd.rawValue
    public var trashedAt: Date?
    /// Where it was when it was trashed, for Put Back.
    public var trashedFromRaw: String?
    @Relationship(deleteRule: .cascade, inverse: \Attachment.item) public var attachments: [Attachment]? = []

    /// Only its first open subtask is in Actions.
    public var isSequential: Bool = false
    /// For a meeting's note, the calendar event it's for: the event's identifier outside the
    /// device (EventKit's `calendarItemExternalIdentifier`), which a repeating event's
    /// occurrences share.
    public var calendarEventID: String?

    public init(title: String = "", bucket: Bucket = .inbox) {
        self.title = title
        self.bucketRaw = bucket.rawValue
    }

    public var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .action }
        set { kindRaw = newValue.rawValue }
    }

    public var bucket: Bucket {
        get { Bucket(rawValue: bucketRaw) ?? .inbox }
        set { bucketRaw = newValue.rawValue }
    }

    public var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    public var timeEstimate: TimeEstimate? {
        get { timeEstimateRaw.flatMap(TimeEstimate.init) }
        set { timeEstimateRaw = newValue?.rawValue }
    }

    public var energy: Energy? {
        get { energyRaw.flatMap(Energy.init) }
        set { energyRaw = newValue?.rawValue }
    }

    public var trashedFrom: Bucket? {
        get { trashedFromRaw.flatMap(Bucket.init) }
        set { trashedFromRaw = newValue?.rawValue }
    }

    public var source: ItemSource {
        get { ItemSource(rawValue: sourceRaw) ?? .quickAdd }
        set { sourceRaw = newValue.rawValue }
    }
}

@Model
public final class Area {
    @Attribute(.preserveValueOnDeletion) public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now

    public var name: String = ""
    public var sortOrder: Double = 0
    @Relationship(deleteRule: .nullify, inverse: \Item.area) public var items: [Item]? = []

    public init(name: String = "") {
        self.name = name
    }
}

@Model
public final class Context {
    @Attribute(.preserveValueOnDeletion) public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now

    public var name: String = ""
    /// An SF Symbol's name.
    public var symbol: String = ""
    public var sortOrder: Double = 0
    public var isBuiltIn: Bool = false
    public var isHidden: Bool = false
    @Relationship(deleteRule: .nullify, inverse: \Item.contexts) public var items: [Item]? = []

    public init(name: String = "", symbol: String = "") {
        self.name = name
        self.symbol = symbol
    }

    /// The contexts made on first launch. Each has a fixed `id`, the same on every device, so two
    /// devices making them before they've synced make the same records rather than duplicates.
    public static let builtIn: [(id: UUID, name: String, symbol: String)] = [
        (UUID(uuidString: "C0000000-0000-4000-8000-000000000002")!, "Calls", "phone"),
        (UUID(uuidString: "C0000000-0000-4000-8000-000000000003")!, "Errands", "bag"),
        (meetingsID, "Meetings", "person.2"),
    ]

    /// The built-in Meetings, once called Agendas. Seeding renames it unless it's
    /// been renamed already.
    public static let meetingsID = UUID(uuidString: "C0000000-0000-4000-8000-000000000006")!

    /// Built-in contexts no longer made: Computer, Home, Office and Anywhere. Their IDs are never
    /// used again. Seeding hides each one that nobody has changed or used.
    public static let retiredBuiltIns: Set<UUID> = [
        UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!,
        UUID(uuidString: "C0000000-0000-4000-8000-000000000004")!,
        UUID(uuidString: "C0000000-0000-4000-8000-000000000005")!,
        anywhereID,
    ]

    /// The retired built-in Anywhere, which means the same as no context. Seeding takes it off
    /// every item and hides it, unless it's been renamed.
    public static let anywhereID = UUID(uuidString: "C0000000-0000-4000-8000-000000000007")!
}

/// How an item repeats. Named so as not to clash
/// with `RepeatRule`, the value it holds; its sync records are still of type `RepeatRule`.
@Model
public final class Repetition {
    @Attribute(.preserveValueOnDeletion) public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now

    public var modeRaw: String = RepeatMode.schedule.rawValue
    /// An iCalendar RRULE, for a schedule.
    public var rrule: String = ""
    public var afterValue: Int = 1
    public var afterUnitRaw: String = RepeatRule.Unit.week.rawValue
    public var showDaysBefore: Int = 0
    public var endDate: Date?
    public var remainingCount: Int?
    /// What the person typed.
    public var naturalText: String = ""
    @Relationship(deleteRule: .nullify, inverse: \Item.repeatRule) public var item: Item?

    public init() {}

    /// The rule as a value, or nil when its RRULE can't be read.
    public var rule: RepeatRule? {
        get {
            let mode: RepeatRule.Mode
            switch RepeatMode(rawValue: modeRaw) ?? .schedule {
            case .schedule:
                guard let recurrence = try? Recurrence(rrule: rrule) else { return nil }
                mode = .schedule(recurrence)
            case .afterCompletion:
                mode = .afterCompletion(value: afterValue, unit: RepeatRule.Unit(rawValue: afterUnitRaw) ?? .week)
            }
            return RepeatRule(mode, showDaysBefore: showDaysBefore, endDate: endDate.map(LocalDate.init(day:)), remainingCount: remainingCount)
        }
        set {
            guard let newValue else { return }
            switch newValue.mode {
            case .schedule(let recurrence):
                modeRaw = RepeatMode.schedule.rawValue
                rrule = recurrence.rrule
            case .afterCompletion(let value, let unit):
                modeRaw = RepeatMode.afterCompletion.rawValue
                afterValue = value
                afterUnitRaw = unit.rawValue
            }
            showDaysBefore = newValue.showDaysBefore
            endDate = newValue.endDate?.storedDate
            remainingCount = newValue.remainingCount
        }
    }
}

@Model
public final class Attachment {
    @Attribute(.preserveValueOnDeletion) public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now

    public var filename: String = ""
    /// A uniform type identifier.
    public var contentType: String = ""
    public var byteSize: Int = 0
    /// The file's contents; a CloudKit asset when synced.
    @Attribute(.externalStorage) public var data: Data?
    @Attribute(.externalStorage) public var thumbnail: Data?
    /// Its owner.
    public var item: Item?

    public init(filename: String = "", contentType: String = "", data: Data? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
        self.byteSize = data?.count ?? 0
    }
}

@Model
public final class ReviewRecord {
    @Attribute(.preserveValueOnDeletion) public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now

    public var startedAt: Date = Date.now
    public var completedAt: Date?
    public var stepsDone: [String] = []

    public init() {}
}

/// The app's settings: one record, synced. Its `id` is fixed, so every device has the same one.
@Model
public final class AppSettings {
    public static let fixedID = UUID(uuidString: "5E770000-0000-4000-8000-000000000001")!

    @Attribute(.preserveValueOnDeletion) public var id: UUID = AppSettings.fixedID
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now

    /// 1 is Sunday and 7 Saturday, as in `Calendar`.
    public var weeklyReviewWeekday: Int = 6
    /// Minutes after midnight.
    public var weeklyReviewTime: Int = 15 * 60
    public var weeklyReviewReminder: Bool = true
    /// Minutes after midnight when the day starts, for stars, hidden items and everything else that
    /// depends on today. See `DayBoundary`.
    public var dayBoundaryTime: Int = 4 * 60
    public var notifyScheduled: Bool = true
    public var notifyDue: Bool = true
    public var notifyFollowUps: Bool = true
    /// Minutes after midnight for due and follow-up notifications.
    public var dueNotificationTime: Int = 9 * 60
    /// The brain dump's prompts; empty for the built-in ones.
    public var brainDumpPrompts: [String] = []

    public init() {}
}

/// The other version of a long text that two devices changed at once. Kept on
/// this device only, for 30 days.
@Model
public final class ConflictedCopy {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    /// The record the text belonged to.
    public var recordType: String = ""
    public var recordName: String = ""
    public var field: String = ""
    public var text: String = ""

    public init(recordType: String, recordName: String, field: String, text: String) {
        self.recordType = recordType
        self.recordName = recordName
        self.field = field
        self.text = text
    }

    public static let keptFor: TimeInterval = 30 * 86400
}

public enum TasksSchema {
    /// The models that sync.
    public static let synced: [any PersistentModel.Type] = [
        Area.self, Context.self, Item.self, Repetition.self,
        Attachment.self, ReviewRecord.self, AppSettings.self,
    ]

    /// Everything in the store: the synced models, conflicted copies, and sync's own state.
    public static let all: [any PersistentModel.Type] = synced + [ConflictedCopy.self, SyncZoneState.self, SyncEntryRow.self]

    public static var schema: Schema { Schema(all) }

    /// A container for a store at `url`, or in memory.
    public static func container(at url: URL?) throws -> ModelContainer {
        let configuration =
            if let url {
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            } else {
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            }
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Makes the built-in contexts and the settings record, where they're missing. They're made
    /// unchanged (`modifiedAt` is `createdAt`), which sync relies on to let another device's
    /// copies win; a change to one must set `modifiedAt`.
    public static func seed(_ context: ModelContext) throws {
        let contexts = try context.fetch(FetchDescriptor<Context>())
        for (index, builtIn) in Context.builtIn.enumerated() where !contexts.contains(where: { $0.id == builtIn.id }) {
            let made = Context(name: builtIn.name, symbol: builtIn.symbol)
            made.id = builtIn.id
            made.isBuiltIn = true
            made.sortOrder = Double(index)
            made.modifiedAt = made.createdAt
            context.insert(made)
        }
        if let anywhere = contexts.first(where: { $0.id == Context.anywhereID }), anywhere.isBuiltIn, anywhere.name == "Anywhere" {
            let now = Date.now
            for item in anywhere.items ?? [] {
                item.contexts = (item.contexts ?? []).filter { $0.id != anywhere.id }
                item.modifiedAt = now
            }
            if !anywhere.isHidden { anywhere.isHidden = true }
        }
        if let meetings = contexts.first(where: { $0.id == Context.meetingsID }), meetings.isBuiltIn, meetings.name == "Agendas" {
            meetings.name = "Meetings"
            meetings.modifiedAt = .now
        }
        for retired in contexts where Context.retiredBuiltIns.contains(retired.id) && retired.isBuiltIn && !retired.isHidden {
            guard retired.modifiedAt == retired.createdAt, (retired.items ?? []).isEmpty else { continue }
            retired.isHidden = true
        }
        if try context.fetchCount(FetchDescriptor<AppSettings>()) == 0 {
            let settings = AppSettings()
            settings.modifiedAt = settings.createdAt
            context.insert(settings)
        }
        if context.hasChanges { try context.save() }
    }
}
