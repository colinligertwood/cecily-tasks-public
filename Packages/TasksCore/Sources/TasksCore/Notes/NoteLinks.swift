import Foundation

/// A link in notes to an item or an area, by its ID: `cecily-tasks://item/<id>` or
/// `cecily-tasks://area/<id>`. It's written as a Markdown link with the target's title as its
/// text, and shown with the target's current title.
public enum NoteLink: Hashable, Sendable {
    case item(UUID)
    case area(UUID)

    public static let scheme = "cecily-tasks"

    public init?(_ string: String) {
        guard let url = URL(string: string), url.scheme == Self.scheme, let host = url.host(),
            let id = UUID(uuidString: url.lastPathComponent), url.pathComponents.count == 2
        else { return nil }
        switch host {
        case "item": self = .item(id)
        case "area": self = .area(id)
        default: return nil
        }
    }

    public var url: String {
        switch self {
        case .item(let id): "\(Self.scheme)://item/\(id.uuidString)"
        case .area(let id): "\(Self.scheme)://area/\(id.uuidString)"
        }
    }

    /// A Markdown link to `url` with `title` as its text.
    public static func markdown(title: String, url: String) -> String {
        let text = title.isEmpty ? url : title.replacing(/([\\\[\]])/) { "\\" + $0.output.1 }
        return "[\(text)](\(url))"
    }

    /// What a link can go to, as offered while a link is typed.
    public struct Target: Equatable, Sendable {
        public let link: NoteLink
        public let title: String
        /// Where it is: its list, or "Area".
        public let place: String
    }

    /// Items and areas whose titles have every word of `query` at the start of one of theirs, in
    /// any order: areas first, then open items before done ones and the most recently changed
    /// first, at most `limit`. Items in the Trash or dropped, and `excluding`, are left out. With
    /// no words, the most recently changed open items.
    public static func targets(
        matching query: String, items: [Item], areas: [Area], excluding: UUID? = nil, limit: Int = 12
    ) -> [Target] {
        let wanted = words(in: query)
        func matches(_ title: String) -> Bool {
            let have = words(in: title)
            return wanted.allSatisfy { word in have.contains { $0.hasPrefix(word) } }
        }
        let areaTargets = areas.filter { !wanted.isEmpty && matches($0.name) }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { Target(link: .area($0.id), title: $0.name, place: "Area") }
        let itemTargets = items.filter {
            $0.id != excluding && $0.bucket != .trash && $0.status != .dropped && !$0.title.isEmpty
                && (wanted.isEmpty ? $0.status == .open : matches($0.title))
        }
        .sorted {
            if ($0.status == .open) != ($1.status == .open) { return $0.status == .open }
            return ($0.modifiedAt, $0.createdAt) > ($1.modifiedAt, $1.createdAt)
        }
        .map { Target(link: .item($0.id), title: $0.title, place: $0.bucket.title) }
        return Array((areaTargets + itemTargets).prefix(limit))
    }

    /// The links' targets as they are now: the title to show, and whether it's gone (deleted, or an
    /// item in the Trash), keyed by link URL. Links that aren't to an item or an area are left out.
    public static func titles(for urls: [String], items: [UUID: Item], areas: [UUID: Area]) -> [String: (title: String?, isGone: Bool)] {
        var titles: [String: (title: String?, isGone: Bool)] = [:]
        for url in urls {
            switch NoteLink(url) {
            case .item(let id):
                let item = items[id]
                titles[url] = (item.map(\.title), item.map { $0.bucket == .trash } ?? true)
            case .area(let id):
                titles[url] = (areas[id]?.name, areas[id] == nil)
            case nil:
                break
            }
        }
        return titles
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}
