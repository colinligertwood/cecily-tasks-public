import Foundation

/// A field value in a sync record. The cases match CloudKit's field types (booleans become
/// integers there), so a record maps straight onto a `CKRecord` later.
public enum SyncValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case strings([String])

    public static func int(_ value: Int) -> SyncValue { .int(Int64(value)) }
    public static func uuid(_ value: UUID?) -> SyncValue { value.map { .string($0.uuidString) } ?? .null }
    public static func uuids(_ values: [UUID]) -> SyncValue { .strings(values.map(\.uuidString)) }

    public var isNull: Bool { self == .null }

    /// CloudKit stores booleans as integers, so 0 and 1 read as booleans too.
    public var boolValue: Bool? {
        switch self {
        case .bool(let v): v
        case .int(0): false
        case .int(1): true
        default: nil
        }
    }

    public var intValue: Int? {
        if case .int(let v) = self { return Int(exactly: v) }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var dateValue: Date? {
        if case .date(let v) = self { return v }
        return nil
    }

    public var dataValue: Data? {
        if case .data(let v) = self { return v }
        return nil
    }

    public var stringsValue: [String]? {
        if case .strings(let v) = self { return v }
        return nil
    }

    public var uuidValue: UUID? { stringValue.flatMap(UUID.init(uuidString:)) }
    public var uuidsValue: [UUID]? { stringsValue?.compactMap(UUID.init(uuidString:)) }
}

extension SyncValue: Codable {
    private enum Key: String, CodingKey {
        case null, bool, int, double, string, date, data, strings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Empty value"))
        }
        switch key {
        case .null: self = .null
        case .bool: self = .bool(try c.decode(Bool.self, forKey: key))
        case .int: self = .int(try c.decode(Int64.self, forKey: key))
        case .double: self = .double(try c.decode(Double.self, forKey: key))
        case .string: self = .string(try c.decode(String.self, forKey: key))
        // Seconds since the reference date, like `Date` itself, so dates survive exactly.
        case .date: self = .date(Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: key)))
        case .data: self = .data(try c.decode(Data.self, forKey: key))
        case .strings: self = .strings(try c.decode([String].self, forKey: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .null: try c.encode(true, forKey: .null)
        case .bool(let v): try c.encode(v, forKey: .bool)
        case .int(let v): try c.encode(v, forKey: .int)
        case .double(let v): try c.encode(v, forKey: .double)
        case .string(let v): try c.encode(v, forKey: .string)
        case .date(let v): try c.encode(v.timeIntervalSinceReferenceDate, forKey: .date)
        case .data(let v): try c.encode(v, forKey: .data)
        case .strings(let v): try c.encode(v, forKey: .strings)
        }
    }
}
