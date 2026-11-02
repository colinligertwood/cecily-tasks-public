import Foundation
import SwiftData
import UniformTypeIdentifiers

/// A file to keep as an item's attachment: its name, its type, what's in it, and its thumbnail.
public struct AttachedFile: Sendable, Equatable {
    public enum Problem: Error, Equatable {
        /// The file, by its name, is bigger than `largest`.
        case tooLarge(String)
    }

    /// The largest file kept, in bytes.
    public static let largest = 50 * 1024 * 1024

    public var name: String
    /// A uniform type identifier.
    public var contentType: String
    public var data: Data
    public var thumbnail: Data?

    /// A file of `data`, refused when it's bigger than `largest`.
    public init(name: String, contentType: String, data: Data, thumbnail: Data? = nil) throws {
        guard data.count <= Self.largest else { throw Problem.tooLarge(name) }
        self.name = name
        self.contentType = contentType
        self.data = data
        self.thumbnail = thumbnail
    }

    /// Reads the file at `url`, with its type from its name, refusing it before it's read when
    /// it's bigger than `largest`.
    public static func read(_ url: URL) throws -> AttachedFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard (values.fileSize ?? 0) <= largest else { throw Problem.tooLarge(url.lastPathComponent) }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        return try AttachedFile(name: url.lastPathComponent, contentType: type.identifier, data: Data(contentsOf: url))
    }

    /// What's said when a file can't be added.
    public static func message(for error: any Error) -> String {
        switch error {
        case Problem.tooLarge(let name): "“\(name)” is bigger than 50 MB, so it wasn’t added."
        default: "Couldn’t add the file. \(error.localizedDescription)"
        }
    }
}

extension Item {
    /// The item's attachments, the oldest first.
    public var attachmentsInOrder: [Attachment] {
        (attachments ?? []).sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Keeps `file` as one of the item's attachments, without saving.
    @discardableResult
    public func attach(_ file: AttachedFile) -> Attachment {
        guard let context = modelContext else { preconditionFailure("The item isn't in a context") }
        let attachment = Attachment(filename: file.name, contentType: file.contentType, data: file.data)
        attachment.thumbnail = file.thumbnail
        context.insert(attachment)
        attachment.item = self
        return attachment
    }
}

extension Attachment {
    /// What an attachment holds, kept when it's deleted, so it can be put back.
    public struct Kept: Sendable {
        let itemID: UUID
        let createdAt: Date
        let filename: String
        let contentType: String
        let data: Data?
        let thumbnail: Data?

        /// Puts the attachment back on its item as a new attachment, without saving; nil when the
        /// item has gone.
        @discardableResult
        public func putBack(in context: ModelContext) -> Attachment? {
            let id = itemID
            guard let item = try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first else { return nil }
            let attachment = Attachment(filename: filename, contentType: contentType, data: data)
            attachment.thumbnail = thumbnail
            attachment.createdAt = createdAt
            context.insert(attachment)
            attachment.item = item
            return attachment
        }
    }

    /// What it holds, to put it back after it's deleted; nil when it isn't on an item.
    public var kept: Kept? {
        guard let item else { return nil }
        return Kept(itemID: item.id, createdAt: createdAt, filename: filename, contentType: contentType, data: data, thumbnail: thumbnail)
    }

    public var type: UTType { UTType(contentType) ?? .data }

    /// Whether it's an image, shown as a picture rather than by its name.
    public var isImage: Bool { type.conforms(to: .image) }

    /// Its size, as Finder shows it ("2.4 MB").
    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    /// Writes its file into `folder`, at `<id>/<filename>`, unless it's there already, for Quick
    /// Look, another app or the share sheet to open.
    public func writeFile(in folder: URL) throws -> URL {
        let url = folder.appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: FullExport.safeFilename(filename), directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data ?? Data()).write(to: url)
        }
        return url
    }
}
