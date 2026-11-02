import Foundation
import SwiftData

/// A model that syncs: its fields, as a list of how each becomes a record field and back. Field
/// names are the model's property names. To-one relationships are references, stored on the side
/// that isn't a list, as the target's record name; to-many relationships are stored only where the
/// other side is a list too (an item's contexts), as a list of record names.
///
/// Fields may be added but never removed or given a new meaning: older and newer versions of the
/// app share records.
public protocol SyncModel: PersistentModel {
    static var recordType: String { get }
    /// Parents before children, so references resolve within one batch of records.
    static var applyOrder: Int { get }
    static var fields: [SyncField<Self>] { get }
    var id: UUID { get set }
    /// `id`'s key path written for the model itself, which is the one a deleted object's
    /// tombstone keeps its value under.
    static var idKeyPath: KeyPath<Self, UUID> { get }
    var modifiedAt: Date { get set }
    init()
}

extension SyncModel {
    public var recordName: String { id.uuidString }
    public var recordID: RecordID { RecordID(type: Self.recordType, name: recordName) }

    public func syncFields() -> [String: SyncValue] {
        Dictionary(uniqueKeysWithValues: Self.fields.map { ($0.name, $0.get(self)) })
    }

    /// Sets every field the record has.
    public func apply(_ record: ServerRecord, _ links: SyncLinks) {
        for field in Self.fields {
            if let value = record.fields[field.name] { field.set(self, value, links) }
        }
    }

    /// A new object for an incoming record, not yet inserted. `apply` sets its fields.
    static func make(from record: ServerRecord) -> Self {
        let object = Self()
        object.id = UUID(uuidString: record.id.name) ?? UUID()
        return object
    }

    static var references: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { field in field.target.map { (field.name, $0) } })
    }

    static var assetFields: Set<String> {
        Set(fields.filter(\.isAsset).map(\.name))
    }

    static var fieldNames: [String] { fields.map(\.name).sorted() }

    static func recordName(from tombstone: HistoryTombstone<Self>) -> String? {
        (tombstone[idKeyPath] as? UUID)?.uuidString
    }
}

/// How one property becomes a record field, and how a record's field is written back.
public struct SyncField<Model: SyncModel> {
    public let name: String
    /// The record type a reference field points to.
    public let target: String?
    /// Whether the field holds a file's contents, synced as a CloudKit asset.
    public let isAsset: Bool
    /// Long text whose losing version is kept as a conflicted copy.
    public let isLongText: Bool
    /// A list that only grows: what arrives is added to what's here, even while this device's own
    /// change waits to be sent, so neither device's additions are lost.
    public let isMerged: Bool
    /// A value of the field's kind, for a record with every field filled (`SyncModels.sampleRecords`).
    public let sample: SyncValue
    let get: (Model) -> SyncValue
    let set: (Model, SyncValue, SyncLinks) -> Void

    init(
        _ name: String, target: String? = nil, isAsset: Bool = false, isLongText: Bool = false, isMerged: Bool = false,
        sample: SyncValue, get: @escaping (Model) -> SyncValue, set: @escaping (Model, SyncValue, SyncLinks) -> Void
    ) {
        self.name = name
        self.sample = sample
        self.target = target
        self.isAsset = isAsset
        self.isLongText = isLongText
        self.isMerged = isMerged
        self.get = get
        self.set = set
    }

    static func string(_ name: String, _ path: ReferenceWritableKeyPath<Model, String>, longText: Bool = false) -> Self {
        Self(
            name, isLongText: longText, sample: .string("schema"), get: { .string($0[keyPath: path]) },
            set: { object, value, _ in object[keyPath: path] = value.stringValue ?? "" })
    }

    static func string(_ name: String, _ path: ReferenceWritableKeyPath<Model, String?>) -> Self {
        Self(
            name, sample: .string("schema"), get: { $0[keyPath: path].map { .string($0) } ?? .null },
            set: { object, value, _ in object[keyPath: path] = value.stringValue })
    }

    static func strings(_ name: String, _ path: ReferenceWritableKeyPath<Model, [String]>, merged: Bool = false) -> Self {
        Self(
            name, isMerged: merged, sample: .strings(["schema"]), get: { .strings($0[keyPath: path]) },
            set: { object, value, _ in
                let arriving = value.stringsValue ?? []
                object[keyPath: path] = merged ? object[keyPath: path] + arriving.filter { !object[keyPath: path].contains($0) } : arriving
            })
    }

    static func int(_ name: String, _ path: ReferenceWritableKeyPath<Model, Int>) -> Self {
        Self(name, sample: .int(1), get: { .int($0[keyPath: path]) }, set: { object, value, _ in object[keyPath: path] = value.intValue ?? 0 })
    }

    static func int(_ name: String, _ path: ReferenceWritableKeyPath<Model, Int?>) -> Self {
        Self(
            name, sample: .int(1), get: { $0[keyPath: path].map { .int($0) } ?? .null },
            set: { object, value, _ in object[keyPath: path] = value.intValue })
    }

    static func double(_ name: String, _ path: ReferenceWritableKeyPath<Model, Double>) -> Self {
        Self(
            name, sample: .double(1), get: { .double($0[keyPath: path]) },
            set: { object, value, _ in object[keyPath: path] = value.doubleValue ?? Double(value.intValue ?? 0) })
    }

    static func bool(_ name: String, _ path: ReferenceWritableKeyPath<Model, Bool>) -> Self {
        Self(
            name, sample: .bool(true), get: { .bool($0[keyPath: path]) },
            set: { object, value, _ in object[keyPath: path] = value.boolValue ?? false })
    }

    static func date(_ name: String, _ path: ReferenceWritableKeyPath<Model, Date>) -> Self {
        Self(
            name, sample: .date(Date(timeIntervalSince1970: 0)), get: { .date($0[keyPath: path]) },
            set: { object, value, _ in if let date = value.dateValue { object[keyPath: path] = date } })
    }

    static func date(_ name: String, _ path: ReferenceWritableKeyPath<Model, Date?>) -> Self {
        Self(
            name, sample: .date(Date(timeIntervalSince1970: 0)), get: { $0[keyPath: path].map { .date($0) } ?? .null },
            set: { object, value, _ in object[keyPath: path] = value.dateValue })
    }

    static func data(_ name: String, _ path: ReferenceWritableKeyPath<Model, Data?>, asset: Bool = false) -> Self {
        Self(
            name, isAsset: asset, sample: .data(Data("schema".utf8)), get: { $0[keyPath: path].map { .data($0) } ?? .null },
            set: { object, value, _ in object[keyPath: path] = value.dataValue })
    }

    static func reference<Target: SyncModel>(_ name: String, _ path: ReferenceWritableKeyPath<Model, Target?>) -> Self {
        Self(
            name, target: Target.recordType, sample: .string(UUID().uuidString),
            get: { $0[keyPath: path].map { .string($0.recordName) } ?? .null },
            set: { object, value, links in object[keyPath: path] = links.resolve(name, value, as: Target.self) })
    }

    static func references<Target: SyncModel>(_ name: String, _ path: ReferenceWritableKeyPath<Model, [Target]?>) -> Self {
        Self(
            name, sample: .strings([UUID().uuidString]), get: { .strings(($0[keyPath: path] ?? []).map(\.recordName).sorted()) },
            set: { object, value, links in object[keyPath: path] = links.resolveAll(name, value, as: Target.self) })
    }
}

/// Finds objects by record name while records are applied, and notes references to objects that
/// haven't arrived yet, to link once they do.
public final class SyncLinks {
    public let context: ModelContext
    /// Fields of the current record that point to something that hasn't arrived.
    var missing: Set<String> = []
    private var cache: [String: [String: any SyncModel]] = [:]

    init(context: ModelContext) {
        self.context = context
    }

    func object<T: SyncModel>(_ type: T.Type, _ name: String) -> T? {
        index(type)[name] as? T
    }

    private func index<T: SyncModel>(_ type: T.Type) -> [String: any SyncModel] {
        if let cached = cache[T.recordType] { return cached }
        let objects = (try? context.fetch(FetchDescriptor<T>())) ?? []
        let byName = Dictionary(objects.map { ($0.recordName, $0 as any SyncModel) }, uniquingKeysWith: { first, _ in first })
        cache[T.recordType] = byName
        return byName
    }

    func register<T: SyncModel>(_ object: T) {
        _ = index(T.self)
        cache[T.recordType]?[object.recordName] = object
    }

    func forget<T: SyncModel>(_ type: T.Type, _ name: String) {
        cache[T.recordType]?[name] = nil
    }

    /// The object a reference points to; nil if it's empty or hasn't arrived (noted in `missing`).
    func resolve<T: SyncModel>(_ field: String, _ value: SyncValue, as type: T.Type) -> T? {
        guard let name = value.stringValue else { return nil }
        if let target = object(type, name) { return target }
        missing.insert(field)
        return nil
    }

    /// The objects a list of references points to that are here, noting the field in `missing`
    /// if any aren't.
    func resolveAll<T: SyncModel>(_ field: String, _ value: SyncValue, as type: T.Type) -> [T] {
        let names = value.stringsValue ?? []
        let found = names.compactMap { object(type, $0) }
        if found.count < names.count { missing.insert(field) }
        return found
    }
}

// MARK: - The models' fields

extension Item: SyncModel {
    public static var recordType: String { "Item" }
    public static var applyOrder: Int { 6 }
    public static var idKeyPath: KeyPath<Item, UUID> { \Item.id }
    public static var fields: [SyncField<Item>] {
        [
            .date("createdAt", \.createdAt), .date("modifiedAt", \.modifiedAt),
            .string("title", \.title), .string("body", \.body, longText: true),
            .string("kindRaw", \.kindRaw), .string("bucketRaw", \.bucketRaw), .string("statusRaw", \.statusRaw),
            .date("completedAt", \.completedAt),
            .reference("area", \.area), .references("contexts", \.contexts),
            .string("waitingOn", \.waitingOn), .date("followUpDate", \.followUpDate), .date("dueDate", \.dueDate),
            .date("scheduledDate", \.scheduledDate), .date("scheduledTime", \.scheduledTime), .date("hideUntil", \.hideUntil),
            .string("timeEstimateRaw", \.timeEstimateRaw), .string("energyRaw", \.energyRaw),
            .reference("parent", \.parent), .double("sortOrder", \.sortOrder),
            .string("sourceRaw", \.sourceRaw),
            .date("trashedAt", \.trashedAt), .string("trashedFromRaw", \.trashedFromRaw),
            .bool("isSequential", \.isSequential),
            .string("calendarEventID", \.calendarEventID),
        ]
    }
    public convenience init() { self.init(title: "") }
}

extension Area: SyncModel {
    public static var recordType: String { "Area" }
    public static var applyOrder: Int { 0 }
    public static var idKeyPath: KeyPath<Area, UUID> { \Area.id }
    public static var fields: [SyncField<Area>] {
        [
            .date("createdAt", \.createdAt), .date("modifiedAt", \.modifiedAt),
            .string("name", \.name), .double("sortOrder", \.sortOrder),
        ]
    }
    public convenience init() { self.init(name: "") }
}

extension Context: SyncModel {
    public static var recordType: String { "Context" }
    public static var applyOrder: Int { 0 }
    public static var idKeyPath: KeyPath<Context, UUID> { \Context.id }
    public static var fields: [SyncField<Context>] {
        [
            .date("createdAt", \.createdAt), .date("modifiedAt", \.modifiedAt),
            .string("name", \.name), .string("symbol", \.symbol), .double("sortOrder", \.sortOrder),
            .bool("isBuiltIn", \.isBuiltIn), .bool("isHidden", \.isHidden),
        ]
    }
    public convenience init() { self.init(name: "") }
}

extension Repetition: SyncModel {
    public static var recordType: String { "RepeatRule" }
    public static var applyOrder: Int { 7 }
    public static var idKeyPath: KeyPath<Repetition, UUID> { \Repetition.id }
    public static var fields: [SyncField<Repetition>] {
        [
            .date("createdAt", \.createdAt), .date("modifiedAt", \.modifiedAt),
            .string("modeRaw", \.modeRaw), .string("rrule", \.rrule), .int("afterValue", \.afterValue),
            .string("afterUnitRaw", \.afterUnitRaw), .int("showDaysBefore", \.showDaysBefore), .date("endDate", \.endDate),
            .int("remainingCount", \.remainingCount), .string("naturalText", \.naturalText),
            .reference("item", \.item),
        ]
    }
}

extension Attachment: SyncModel {
    public static var recordType: String { "Attachment" }
    public static var applyOrder: Int { 8 }
    public static var idKeyPath: KeyPath<Attachment, UUID> { \Attachment.id }
    public static var fields: [SyncField<Attachment>] {
        [
            .date("createdAt", \.createdAt), .date("modifiedAt", \.modifiedAt),
            .string("filename", \.filename), .string("contentType", \.contentType), .int("byteSize", \.byteSize),
            .data("data", \.data, asset: true), .data("thumbnail", \.thumbnail, asset: true),
            .reference("item", \.item),
        ]
    }
    public convenience init() { self.init(filename: "") }
}

extension ReviewRecord: SyncModel {
    public static var recordType: String { "ReviewRecord" }
    public static var applyOrder: Int { 0 }
    public static var idKeyPath: KeyPath<ReviewRecord, UUID> { \ReviewRecord.id }
    public static var fields: [SyncField<ReviewRecord>] {
        [
            .date("createdAt", \.createdAt), .date("modifiedAt", \.modifiedAt),
            .date("startedAt", \.startedAt), .date("completedAt", \.completedAt), .strings("stepsDone", \.stepsDone, merged: true),
        ]
    }
}

extension AppSettings: SyncModel {
    public static var recordType: String { "AppSettings" }
    public static var applyOrder: Int { 0 }
    public static var idKeyPath: KeyPath<AppSettings, UUID> { \AppSettings.id }
    public static var fields: [SyncField<AppSettings>] {
        [
            .date("createdAt", \.createdAt), .date("modifiedAt", \.modifiedAt),
            .int("weeklyReviewWeekday", \.weeklyReviewWeekday), .int("weeklyReviewTime", \.weeklyReviewTime),
            .bool("weeklyReviewReminder", \.weeklyReviewReminder),
            .int("dayBoundaryTime", \.dayBoundaryTime),
            .bool("notifyScheduled", \.notifyScheduled), .bool("notifyDue", \.notifyDue), .bool("notifyFollowUps", \.notifyFollowUps),
            .int("dueNotificationTime", \.dueNotificationTime),
            .strings("brainDumpPrompts", \.brainDumpPrompts),
        ]
    }
}

public enum SyncModels {
    public static let all: [any SyncModel.Type] = [
        Area.self, Context.self, ReviewRecord.self, AppSettings.self,
        Item.self, Repetition.self, Attachment.self,
    ]

    public static let byType: [String: any SyncModel.Type] = Dictionary(uniqueKeysWithValues: all.map { ($0.recordType, $0) })

    /// What the CloudKit coding needs to know about the models (see `CloudKitSchema`).
    public static var references: [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.recordType, $0.references) })
    }

    public static var assets: [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.recordType, $0.assetFields) })
    }

    /// One record of each type with every field filled, made as sync makes them: for writing every
    /// record type and field into CloudKit's schema.
    public static func sampleRecords() -> [ServerRecord] {
        all.map { sampleRecord(of: $0) }
    }

    private static func sampleRecord<T: SyncModel>(of type: T.Type) -> ServerRecord {
        ServerRecord(
            id: RecordID(type: T.recordType, uid: UUID()), tag: nil,
            fields: Dictionary(uniqueKeysWithValues: T.fields.map { ($0.name, $0.sample) }))
    }

    public static var fieldNames: [String: [String]] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.recordType, $0.fieldNames) })
    }

    public static var longTextFields: [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.recordType, longText(of: $0)) })
    }

    private static func longText<T: SyncModel>(of type: T.Type) -> Set<String> {
        Set(T.fields.filter(\.isLongText).map(\.name))
    }

    public static var mergedFields: [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.recordType, merged(of: $0)) })
    }

    private static func merged<T: SyncModel>(of type: T.Type) -> Set<String> {
        Set(T.fields.filter(\.isMerged).map(\.name))
    }
}
