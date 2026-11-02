import Foundation
import SwiftData

/// Everything in the store, written to a folder and read back: `Cecily Tasks.json` with every
/// synced record, `Attachments/` with the attachments' files, and a Markdown file for each list
/// and each area (`MarkdownExport`).
///
/// A record's fields are its synced fields, by the names in `SyncMapping`, with references as
/// record names. A file's contents are kept in `Attachments/`, and the record names its path.
public enum FullExport {
    public static let dataFile = "Cecily Tasks.json"
    public static let attachmentsFolder = "Attachments"
    public static let formatVersion = 1

    public enum Failure: LocalizedError, Equatable {
        case storeNotEmpty
        case notAnExport
        case newerVersion
        case missingFile(String)

        public var errorDescription: String? {
            switch self {
            case .storeNotEmpty: "A backup can only be restored when there are no tasks, areas, or reviews yet."
            case .notAnExport: "This folder isn’t a backup from Cecily Tasks."
            case .newerVersion: "This backup was made by a newer version of Cecily Tasks."
            case .missingFile(let path): "The backup is missing \(path)."
            }
        }
    }

    /// What `Cecily Tasks.json` holds.
    public struct Contents: Codable, Equatable {
        public var version: Int
        public var exportedAt: Date
        public var records: [Record]
    }

    /// One record: its fields, and the paths of its files within the export's folder.
    public struct Record: Codable, Equatable {
        public var type: String
        public var id: String
        public var fields: [String: SyncValue]
        public var files: [String: String]
    }

    // MARK: Writing

    /// Writes everything in `context` into `folder`, which is made if it's missing.
    public static func write(_ context: ModelContext, to folder: URL, now: Date = .now, calendar: Calendar = .current) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [Record] = []
        for type in SyncModels.all {
            records += try export(type, context: context, folder: folder)
        }
        let contents = Contents(version: formatVersion, exportedAt: now, records: records)
        try encoder.encode(contents).write(to: folder.appending(path: dataFile))
        for (path, text) in try MarkdownExport.files(context, calendar: calendar) {
            let url = folder.appending(path: path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    private static func export<T: SyncModel>(_ type: T.Type, context: ModelContext, folder: URL) throws -> [Record] {
        let objects = try context.fetch(FetchDescriptor<T>()).sorted { $0.recordName < $1.recordName }
        return try objects.map { object in
            var fields: [String: SyncValue] = [:]
            var files: [String: String] = [:]
            for field in T.fields {
                let value = field.get(object)
                guard field.isAsset else {
                    fields[field.name] = value
                    continue
                }
                guard let data = value.dataValue else { continue }
                let path = filePath(for: object, field: field.name)
                let url = folder.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                files[field.name] = path
            }
            return Record(type: T.recordType, id: object.recordName, fields: fields, files: files)
        }
    }

    /// `Attachments/<id>/<filename>` for an attachment's file, and `Attachments/<id>/<field>` for
    /// anything else.
    private static func filePath(for object: some SyncModel, field: String) -> String {
        let name =
            if let attachment = object as? Attachment, field == "data" { safeFilename(attachment.filename) } else { field }
        return "\(attachmentsFolder)/\(object.recordName)/\(name)"
    }

    /// `name` with nothing in it that a file system would read as a folder or refuse.
    public static func safeFilename(_ name: String) -> String {
        let cleaned = name.replacing(/[\/:\\\u{0}]/, with: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "file" + cleaned : cleaned
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: Restoring

    /// Reads an export from `folder` into `context` and saves it. Records keep their ids, dates and
    /// `modifiedAt`. The store has to be empty but for the built-in records every store has, which
    /// the export's copies replace.
    public static func restore(from folder: URL, into context: ModelContext) throws {
        guard try isEmpty(context) else { throw Failure.storeNotEmpty }
        let contents = try read(folder)
        let links = SyncLinks(context: context)
        let records = contents.records.sorted { order($0) < order($1) }
        var objects: [(any SyncModel, Record)] = []
        for record in records {
            guard let type = SyncModels.byType[record.type] else { continue }
            objects.append((object(type, record.id, links: links), record))
        }
        for (object, record) in objects {
            var fields = record.fields
            for (field, path) in record.files {
                let url = folder.appending(path: path)
                guard let data = try? Data(contentsOf: url) else { throw Failure.missingFile(path) }
                fields[field] = .data(data)
            }
            apply(object, ServerRecord(id: RecordID(type: record.type, name: record.id), tag: nil, fields: fields), links: links)
        }
        try context.save()
    }

    /// The contents of the export in `folder`.
    public static func read(_ folder: URL) throws -> Contents {
        guard let data = try? Data(contentsOf: folder.appending(path: dataFile)) else { throw Failure.notAnExport }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let contents = try? decoder.decode(Contents.self, from: data) else { throw Failure.notAnExport }
        guard contents.version <= formatVersion else { throw Failure.newerVersion }
        return contents
    }

    /// Whether the store has nothing in it but the built-in contexts and the settings.
    public static func isEmpty(_ context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<Item>()) == 0
            && context.fetchCount(FetchDescriptor<Area>()) == 0
            && context.fetchCount(FetchDescriptor<ReviewRecord>()) == 0
            && context.fetchCount(FetchDescriptor<Repetition>()) == 0
            && context.fetchCount(FetchDescriptor<Attachment>()) == 0
            && context.fetch(FetchDescriptor<Context>()).allSatisfy(\.isBuiltIn)
    }

    private static func order(_ record: Record) -> Int {
        SyncModels.byType[record.type]?.applyOrder ?? .max
    }

    /// The object already in the store with this record name, or a new one, inserted.
    private static func object<T: SyncModel>(_ type: T.Type, _ name: String, links: SyncLinks) -> any SyncModel {
        if let existing = links.object(T.self, name) { return existing }
        let object = T.make(from: ServerRecord(id: RecordID(type: T.recordType, name: name), tag: nil, fields: [:]))
        links.context.insert(object)
        links.register(object)
        return object
    }

    private static func apply<T: SyncModel>(_ object: T, _ record: ServerRecord, links: SyncLinks) {
        object.apply(record, links)
    }
}
