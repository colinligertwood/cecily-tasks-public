import CloudKit
import Foundation

/// How a zone's records are stored in CloudKit: one `CKRecord` per record, of the model's type,
/// with one field per synced property.
///
/// - Every field goes in `encryptedValues`, except references and assets, which CloudKit can't
///   encrypt that way: references become plain `CKRecord.Reference`s with no action (the app
///   deletes children itself), and asset fields become `CKAsset`s, which CloudKit encrypts by
///   itself.
/// - A list of references (an item's contexts, say) is a list of record names, encrypted.
/// - Booleans are stored as integers; `SyncValue.boolValue` reads them back.
/// - Record names are `Type_uuid`.
/// - No field name starts with an underscore: CloudKit refuses those as system fields.
/// - A record's change tag is its encoded system fields.
public struct CloudKitSchema: Sendable {
    public var zoneID: CKRecordZone.ID
    /// For each record type, its reference fields and the type each one points to.
    public var references: [String: [String: String]]
    /// For each record type, its fields that hold a file's contents.
    public var assets: [String: Set<String>]
    /// Every synced field of each type, so a fetched record lists empty ones too: a field cleared
    /// on another device is cleared here.
    public var fields: [String: [String]]

    public init(zoneID: CKRecordZone.ID, references: [String: [String: String]], assets: [String: Set<String>], fields: [String: [String]]) {
        self.zoneID = zoneID
        self.references = references
        self.assets = assets
        self.fields = fields
    }

    // MARK: - Names

    public func recordName(_ id: RecordID) -> String {
        "\(id.type)_\(id.name)"
    }

    public func recordID(_ id: RecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(id), zoneID: zoneID)
    }

    /// The record a CloudKit record name stands for; nil for anything that isn't the app's.
    public func recordID(_ ck: CKRecord.ID) -> RecordID? {
        let parts = ck.recordName.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, fields[String(parts[0])] != nil else { return nil }
        return RecordID(type: String(parts[0]), name: String(parts[1]))
    }

    // MARK: - Coding

    /// The `CKRecord` to save: the server's system fields when the record has been saved before,
    /// so the save carries its change tag, plus the fields being sent. Fields not set are left as
    /// the server has them. Asset contents are written to files in `folder` for CloudKit to upload.
    public func ckRecord(_ record: ServerRecord, assetFolder folder: URL) throws -> CKRecord {
        let ck: CKRecord
        if let tag = record.tag {
            ck = try Self.record(fromSystemFields: tag)
        } else {
            ck = CKRecord(recordType: record.id.type, recordID: recordID(record.id))
        }
        let references = references[record.id.type] ?? [:]
        let assets = assets[record.id.type] ?? []
        for (field, value) in record.fields {
            if let target = references[field] {
                ck[field] = value.stringValue.map {
                    CKRecord.Reference(recordID: recordID(RecordID(type: target, name: $0)), action: .none)
                }
            } else if assets.contains(field) {
                if let data = value.dataValue, !data.isEmpty {
                    let file = folder.appending(path: "\(recordName(record.id))-\(field)-\(UUID().uuidString)")
                    try data.write(to: file)
                    ck[field] = CKAsset(fileURL: file)
                } else {
                    ck[field] = nil
                }
            } else {
                ck.encryptedValues[field] = Self.cloudKitValue(value)
            }
        }
        return ck
    }

    /// A fetched or saved `CKRecord` as a sync record, with every known field (empty ones as
    /// `.null`) and any fields from newer versions of the app. Nil for a record that isn't the
    /// app's.
    public func serverRecord(_ ck: CKRecord) -> ServerRecord? {
        let type = ck.recordType
        guard let id = recordID(ck.recordID), id.type == type else { return nil }
        var values: [String: SyncValue] = [:]
        for field in fields[type] ?? [] { values[field] = .null }
        for field in ck.encryptedValues.allKeys() {
            values[field] = Self.syncValue(ck.encryptedValues[field])
        }
        for (field, target) in references[type] ?? [:] {
            guard let reference = ck[field] as? CKRecord.Reference else { continue }
            let prefix = "\(target)_"
            let recordName = reference.recordID.recordName
            values[field] = recordName.hasPrefix(prefix) ? .string(String(recordName.dropFirst(prefix.count))) : .null
        }
        for field in assets[type] ?? [] {
            guard let asset = ck[field] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) else { continue }
            values[field] = .data(data)
        }
        return ServerRecord(id: id, tag: Self.systemFields(of: ck), fields: values)
    }

    // MARK: - System fields

    public static func systemFields(of ck: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        ck.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public enum CodingError: Error {
        case badSystemFields
    }

    public static func record(fromSystemFields data: Data) throws -> CKRecord {
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder) else { throw CodingError.badSystemFields }
        return record
    }

    // MARK: - Values

    static func cloudKitValue(_ value: SyncValue) -> (any __CKRecordObjCValue)? {
        switch value {
        case .null: nil
        case .bool(let b): NSNumber(value: Int64(b ? 1 : 0))
        case .int(let i): NSNumber(value: i)
        case .double(let d): NSNumber(value: d)
        case .string(let s): s as NSString
        case .date(let d): d as NSDate
        case .data(let d): d as NSData
        case .strings(let list): list as NSArray
        }
    }

    static func syncValue(_ value: Any?) -> SyncValue {
        switch value {
        case nil: .null
        case let s as String: .string(s)
        case let d as Date: .date(d)
        case let d as Data: .data(d)
        case let list as [String]: .strings(list)
        case let n as NSNumber: CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.int64Value)
        default: .null
        }
    }
}
