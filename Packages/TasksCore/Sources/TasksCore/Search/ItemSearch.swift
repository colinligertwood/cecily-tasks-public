import Foundation

/// Finding items by the words in their titles, notes and attachments' file names.
/// Each word typed has to start a word somewhere in the item, in any order, ignoring case
/// and accents: "dent appo" finds "Dentist appointment".
public enum ItemSearch {
    /// Narrows what's found, beyond the words.
    public struct Filter: Equatable, Sendable {
        public enum Status: String, CaseIterable, Sendable {
            case any
            case open
            case done
        }

        /// Only items with this context.
        public var context: UUID?
        public var status: Status
        /// Only items with an attachment.
        public var hasAttachments: Bool

        public init(context: UUID? = nil, status: Status = .any, hasAttachments: Bool = false) {
            self.context = context
            self.status = status
            self.hasAttachments = hasAttachments
        }

        /// Whether it narrows anything.
        public var isOn: Bool { self != Filter() }
    }

    /// An item found, with the part of its notes that has the first word found, when its notes
    /// have one of the words and its title doesn't have them all.
    public struct Result: Identifiable {
        public let item: Item
        public let excerpt: String?
        public var id: UUID { item.id }
    }

    /// The items found in one list.
    public struct Group: Identifiable {
        public let bucket: Bucket
        public let results: [Result]
        public var id: Bucket { bucket }
    }

    /// The lists results are grouped in, in this order.
    public static let buckets: [Bucket] = [.inbox, .action, .waiting, .someday, .reference]

    /// `items` that have every word of `query` and pass `filter` and `keeping`, grouped by list,
    /// open ones first and then the most recently changed. Items in the Trash or dropped are left
    /// out, and nothing is found for a query with no words.
    public static func results(_ items: [Item], query: String, filter: Filter = Filter(), keeping: (Item) -> Bool = { _ in true }) -> [Group] {
        let wanted = words(in: query)
        guard !wanted.isEmpty else { return [] }
        var found: [Bucket: [Result]] = [:]
        for item in items where item.bucket != .trash && item.status != .dropped && passes(item, filter) && keeping(item) {
            guard let result = match(item, wanted) else { continue }
            found[item.bucket, default: []].append(result)
        }
        return buckets.compactMap { bucket in
            guard let results = found[bucket] else { return nil }
            let sorted = results.sorted {
                let (a, b) = ($0.item, $1.item)
                if (a.status == .open) != (b.status == .open) { return a.status == .open }
                return (a.modifiedAt, a.createdAt) > (b.modifiedAt, b.createdAt)
            }
            return Group(bucket: bucket, results: sorted)
        }
    }

    private static func passes(_ item: Item, _ filter: Filter) -> Bool {
        if let context = filter.context, !(item.contexts ?? []).contains(where: { $0.id == context }) { return false }
        switch filter.status {
        case .any: break
        case .open: if item.status != .open { return false }
        case .done: if item.status != .done { return false }
        }
        if filter.hasAttachments, (item.attachments ?? []).isEmpty { return false }
        return true
    }

    private static func match(_ item: Item, _ wanted: [String]) -> Result? {
        let title = words(in: item.title)
        let notes = MarkdownText.plain(item.body)
        let noteWords = words(in: notes)
        let files = (item.attachments ?? []).flatMap { words(in: $0.filename) }
        let all = title + noteWords + files
        guard wanted.allSatisfy({ word in all.contains { $0.hasPrefix(word) } }) else { return nil }
        let titleHasAll = wanted.allSatisfy { word in title.contains { $0.hasPrefix(word) } }
        let excerpt = titleHasAll ? nil : self.excerpt(notes, around: wanted)
        return Result(item: item, excerpt: excerpt)
    }

    /// `notes` from a few words before the first word that starts with one of `wanted`, with "…"
    /// in front when it doesn't start at the beginning; nil when no word in it matches.
    static func excerpt(_ notes: String, around wanted: [String], wordsBefore: Int = 3) -> String? {
        var starts: [String.Index] = []
        var index = notes.startIndex
        var inWord = false
        while index < notes.endIndex {
            let isWord = notes[index].isLetter || notes[index].isNumber
            if isWord && !inWord { starts.append(index) }
            inWord = isWord
            index = notes.index(after: index)
        }
        guard
            let first = starts.firstIndex(where: { start in
                let word = fold(String(notes[start...].prefix { $0.isLetter || $0.isNumber }))
                return wanted.contains { word.hasPrefix($0) }
            })
        else { return nil }
        let from = max(first - wordsBefore, 0)
        let text = String(notes[starts[from]...])
        return from == 0 ? text : "…" + text
    }

    private static func words(in text: String) -> [String] {
        fold(text).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// The searches made last, most recent first, kept on the device.
public enum RecentSearches {
    /// How many are kept.
    public static let limit = 10

    /// `recent` with `query` first, trimmed, once, ignoring case; unchanged for an empty query.
    public static func adding(_ query: String, to recent: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recent }
        let others = recent.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        return Array(([query] + others).prefix(limit))
    }
}
