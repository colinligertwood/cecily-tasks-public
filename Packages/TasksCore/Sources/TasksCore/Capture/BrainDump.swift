import Foundation

/// The guided brain dump's prompts: one screen each, to bring open
/// commitments to mind. Each is stored as one line, "Title: what to think about".
public enum BrainDump {
    public struct Prompt: Hashable, Sendable {
        public var title: String
        public var detail: String

        public init(_ line: String) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            title = parts.first ?? ""
            detail = parts.count > 1 ? parts[1] : ""
        }

        public var line: String { detail.isEmpty ? title : "\(title): \(detail)" }
    }

    public static let defaultLines = [
        "Work: projects started or promised, people you owe something, emails needing replies, upcoming deadlines, things to delegate.",
        "Home: repairs, purchases, admin, paperwork, household.",
        "Money: bills, taxes, insurance, banking, subscriptions.",
        "Health: appointments, fitness, prescriptions.",
        "People: calls to make, things to tell or ask someone, birthdays, gifts.",
        "Errands: things to buy, pick up, return.",
        "Ideas: things to learn, try, read, watch, travel.",
        "Anything else on your mind.",
    ]

    /// The prompts in use: the settings' own, or the built-in ones when there are none.
    public static func prompts(_ lines: [String]) -> [Prompt] {
        let own = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (own.isEmpty ? defaultLines : own).map(Prompt.init)
    }
}
