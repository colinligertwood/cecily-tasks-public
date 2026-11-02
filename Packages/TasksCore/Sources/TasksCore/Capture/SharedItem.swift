import Foundation
import SwiftData

/// What another app shared through the Share Sheet, as an Inbox item: a title, notes, and a file
/// if one was shared.
public struct SharedItem: Sendable {
    /// A shared file, kept as an attachment.
    public struct File: Sendable {
        public var name: String
        /// A uniform type identifier.
        public var contentType: String
        public var data: Data

        public init(name: String, contentType: String, data: Data) {
            self.name = name
            self.contentType = contentType
            self.data = data
        }
    }

    public enum Problem: Error, Equatable {
        /// The file is bigger than `largestFile`.
        case tooLarge
        /// Nothing that could be read was shared.
        case nothing
    }

    /// The largest file kept, in bytes.
    public static let largestFile = AttachedFile.largest

    public var title: String
    /// Text for the notes, apart from the link.
    public var text: String
    /// A link back to what was shared, at the end of the notes.
    public var link: URL?
    public var file: File?

    public init(title: String, text: String = "", link: URL? = nil, file: File? = nil) {
        self.title = title
        self.text = text
        self.link = link
        self.file = file
    }

    /// Reads what was shared, any of which may be missing: a link, with the page's title if it's
    /// known; some text; a file. Text whose first line isn't the title goes in the notes.
    public static func read(link: URL? = nil, pageTitle: String? = nil, text: String? = nil, file: File? = nil) throws -> SharedItem {
        if let file, file.data.count > largestFile { throw Problem.tooLarge }
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let pageTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title: String
        var notes = text
        if !pageTitle.isEmpty {
            title = pageTitle
            if text == link?.absoluteString || text == pageTitle { notes = "" }
        } else if !text.isEmpty, text != link?.absoluteString {
            title = String(lines[0]).trimmingCharacters(in: .whitespaces)
            notes = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        } else if let file {
            title = (file.name as NSString).deletingPathExtension
            notes = ""
        } else if let link {
            title = Self.title(for: link)
            notes = ""
        } else {
            throw Problem.nothing
        }
        return SharedItem(title: title, text: notes, link: link, file: file)
    }

    /// A link's title when the page's isn't known: its host and path, or the link as it is.
    static func title(for link: URL) -> String {
        guard let host = link.host(), !host.isEmpty else { return link.absoluteString }
        let path = link.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return path.isEmpty ? site : "\(site)/\(path)"
    }

    /// The notes, as Markdown: the text, then the link, which opens what was shared.
    public var notes: String {
        guard let link else { return text }
        return (text.isEmpty ? "" : text + "\n\n") + "<\(link.absoluteString)>"
    }

    /// Inserts it into the Inbox, with its notes, without saving.
    @discardableResult
    public func add(to context: ModelContext) -> Item {
        let item = Item(title: title, bucket: .inbox)
        item.body = notes
        item.sortOrder = NewRecord.topOrder(in: context)
        item.source = .share
        context.insert(item)
        if let file {
            let attachment = Attachment(filename: file.name, contentType: file.contentType, data: file.data)
            context.insert(attachment)
            attachment.item = item
        }
        return item
    }
}
