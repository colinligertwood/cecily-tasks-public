import Foundation
import SwiftData

/// The items waiting for one person.
public struct WaitingGroup: Identifiable {
    /// Nil for items waiting for no one named.
    public let person: String?
    public let items: [Item]

    public var id: String { person.map { "person-\($0.lowercased())" } ?? "no-person" }
}

/// A tab of Waiting's index: a letter people's names start with, or no one named.
public enum WaitingTab: Hashable, Sendable {
    /// "A" to "Z", or "#" for names that start with anything else.
    case letter(String)
    case noOne

    /// The letters A to Z.
    public static let alphabet = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) }

    /// A to Z, then "#" and no one named when a group is filed under them.
    public static func tabs(for groups: [WaitingGroup]) -> [WaitingTab] {
        let used = Set(groups.map(\.tab))
        return alphabet.map { .letter($0) } + [.letter("#"), .noOne].filter(used.contains)
    }
}

extension WaitingGroup {
    /// The tab the group is filed under: its person's first letter without accents, or "#" when
    /// that isn't A to Z.
    public var tab: WaitingTab {
        guard let person else { return .noOne }
        let first = person.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).prefix(1).uppercased()
        return .letter(WaitingTab.alphabet.contains(first) ? first : "#")
    }
}

public enum WaitingList {
    /// Waiting's items on `today`, open or done since `doneSince`, not hidden,
    /// grouped by who they're waiting for in alphabetical order with no one last. Names that
    /// differ only in case or spaces are one person, named as the first item has it. Each group is
    /// soonest follow-up first, with those without one last, then in the list's order.
    public static func groups(_ items: [Item], today: LocalDate, doneSince: Date?, showsHidden: Bool = false) -> [WaitingGroup] {
        let shown = items.filter {
            $0.bucket == .waiting && $0.isListed(today: today, doneSince: doneSince, showsHidden: showsHidden)
        }
        var byPerson: [String: (name: String, items: [Item])] = [:]
        var nobody: [Item] = []
        for item in shown {
            let name = (item.waitingOn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                nobody.append(item)
            } else {
                byPerson[name.lowercased(), default: (name, [])].items.append(item)
            }
        }
        func ordered(_ items: [Item]) -> [Item] {
            items.sorted { a, b in
                switch (a.followUpDate, b.followUpDate) {
                case (let x?, let y?) where x != y: x < y
                case (.some, nil): true
                case (nil, .some): false
                default: Item.inListOrder(a, b)
                }
            }
        }
        let groups = byPerson.sorted { $0.key < $1.key }.map { WaitingGroup(person: $0.value.name, items: ordered($0.value.items)) }
        return nobody.isEmpty ? groups : groups + [WaitingGroup(person: nil, items: ordered(nobody))]
    }
}

extension WaitingList {
    /// Everyone items outside the trash are waiting for, in alphabetical order. Names that differ
    /// only in case or spaces are one person, named as the most recently changed item has it.
    public static func people(_ items: [Item]) -> [String] {
        var byKey: [String: (name: String, modifiedAt: Date)] = [:]
        for item in items where item.bucket != .trash {
            let name = (item.waitingOn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let known = byKey[name.lowercased()], known.modifiedAt >= item.modifiedAt { continue }
            byKey[name.lowercased()] = (name, item.modifiedAt)
        }
        return byKey.values.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The names among `people` that `typed` could be the start of, ignoring case and accents:
    /// those it starts first, then those with a later word it starts. Leaves out the name already
    /// typed, and gives none when nothing is.
    public static func matches(_ typed: String, among people: [String]) -> [String] {
        let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let start = fold(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !start.isEmpty else { return [] }
        let others = people.filter { fold($0) != start }
        let whole = others.filter { fold($0).hasPrefix(start) }
        let word = others.filter { name in
            !fold(name).hasPrefix(start) && fold(name).split(whereSeparator: \.isWhitespace).dropFirst().contains { $0.hasPrefix(start) }
        }
        return whole + word
    }
}

extension Clarifier {
    /// Adds an action to follow up a waiting item: "Follow up with Sam about the quote", at the top
    /// of Actions, in Calls and the item's project. The waiting item stays as it is.
    @MainActor
    public static func nudge(_ item: Item, in context: ModelContext) -> Undo {
        let person = (item.waitingOn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let made = NewRecord.item(in: .action, in: context)
        made.title = person.isEmpty ? "Follow up about \(item.title)" : "Follow up with \(person) about \(item.title)"
        made.parent = item.project
        made.area = item.area
        let calls = Context.builtIn.first { $0.name == "Calls" }?.id
        made.contexts = ((try? context.fetch(FetchDescriptor<Context>())) ?? []).filter { $0.id == calls }
        return Undo(before: [(item.recordID, item.syncFields())], made: [made.recordID], title: item.title)
    }

    /// Takes waiting items back to do them yourself: each goes to Actions, keeping its project.
    public static func takeBack(_ items: [Item], at now: Date = .now) -> Undo? {
        let moving = items.filter { $0.bucket == .waiting }
        guard !moving.isEmpty else { return nil }
        let undo = Undo(moving, title: moving.count == 1 ? moving[0].title : "\(moving.count) items")
        for item in moving {
            item.bucket = .action
            item.modifiedAt = now
        }
        return undo
    }
}
