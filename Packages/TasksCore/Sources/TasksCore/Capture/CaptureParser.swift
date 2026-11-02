import Foundation

/// One captured line: its title, and the fields its tokens filled in. The item still goes to the
/// Inbox; the fields just make clarifying it quicker.
public struct CaptureDraft: Hashable, Sendable {
    public var title: String
    /// The project named with `#`, as it's spelt in the store.
    public var project: String?
    /// The contexts named with `@`, as they're spelt in the store.
    public var contexts: [String] = []
    public var dueDate: LocalDate?
    public var scheduledDate: LocalDate?
    public var repeatRule: RepeatRule?
    /// What the person typed for the repeat, kept with the rule.
    public var repeatText: String?

    public init(title: String) {
        self.title = title
    }
}

/// The projects and contexts a capture can name. A name matches whatever its case, and with
/// hyphens or underscores for spaces: `#kitchen-refit` names "Kitchen refit".
public struct CaptureVocabulary: Sendable {
    public var projects: [String]
    public var contexts: [String]

    public init(projects: [String] = [], contexts: [String] = []) {
        self.projects = projects
        self.contexts = contexts
    }

    func project(_ token: String) -> String? { Self.match(token, in: projects) }
    func context(_ token: String) -> String? { Self.match(token, in: contexts) }

    private static func match(_ token: String, in names: [String]) -> String? {
        let key = normalized(token)
        guard !key.isEmpty else { return nil }
        return names.first { normalized($0) == key }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacing(/[-_\s]+/, with: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Reads quick-capture text. Each line that isn't empty is an item. Tokens
/// fill in fields and are taken out of the title:
///
/// - `#project` and `@context`, when a project or context of that name exists;
/// - `due:fri`, `due:tomorrow`, `due:2026-11-06`, `due:+3d` for a due date;
/// - `!tomorrow` and the same forms for a scheduled date;
/// - `every day`, `every 2 weeks`, `every weekday`, `every monday` and the like for a repeat.
///
/// Anything it doesn't recognise stays in the title as typed.
public enum CaptureParser {
    public static func parse(_ text: String, today: LocalDate, vocabulary: CaptureVocabulary = CaptureVocabulary()) -> [CaptureDraft] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { parseLine($0, today: today, vocabulary: vocabulary) }
            .filter { !$0.title.isEmpty || $0.project != nil }
    }

    static func parseLine(_ line: String, today: LocalDate, vocabulary: CaptureVocabulary) -> CaptureDraft {
        var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var draft = CaptureDraft(title: "")
        if let (range, rule, text) = repeatPhrase(in: words, today: today) {
            draft.repeatRule = rule
            draft.repeatText = text
            words.removeSubrange(range)
        }
        var kept: [String] = []
        for word in words {
            let lower = word.lowercased()
            if word.hasPrefix("#"), draft.project == nil, let name = vocabulary.project(String(word.dropFirst())) {
                draft.project = name
            } else if word.hasPrefix("@"), let name = vocabulary.context(String(word.dropFirst())) {
                if !draft.contexts.contains(name) { draft.contexts.append(name) }
            } else if lower.hasPrefix("due:"), draft.dueDate == nil, let date = day(String(lower.dropFirst(4)), today: today) {
                draft.dueDate = date
            } else if word.hasPrefix("!"), draft.scheduledDate == nil, let date = day(String(lower.dropFirst()), today: today) {
                draft.scheduledDate = date
            } else {
                kept.append(word)
            }
        }
        draft.title = kept.joined(separator: " ")
        return draft
    }

    // MARK: Days

    static let weekdayNames: [(names: [String], weekday: Int)] = [
        (["sun", "sunday"], 1), (["mon", "monday"], 2), (["tue", "tues", "tuesday"], 3), (["wed", "wednesday"], 4),
        (["thu", "thur", "thurs", "thursday"], 5), (["fri", "friday"], 6), (["sat", "saturday"], 7),
    ]

    /// A day written as `today`, `tomorrow`, a weekday (today when it's that day, or the next one),
    /// `yyyy-mm-dd`, or `+3d` / `+2w` from today.
    public static func day(_ text: String, today: LocalDate) -> LocalDate? {
        switch text {
        case "today", "tod": return today
        case "tomorrow", "tom", "tmr": return today.adding(days: 1)
        default: break
        }
        if let weekday = weekdayNames.first(where: { $0.names.contains(text) })?.weekday {
            return today.adding(days: (weekday - today.weekday + 7) % 7)
        }
        if let date = LocalDate(text), text.count == 10 {
            return date
        }
        if let match = text.wholeMatch(of: /\+(\d{1,3})([dw])/), let count = Int(match.1) {
            return today.adding(days: match.2 == "w" ? count * 7 : count)
        }
        return nil
    }

    // MARK: Repeats

    /// The rule an `every …` phrase gives, such as "every 2 weeks", or nil when it isn't one.
    public static func repeatRule(_ phrase: String, today: LocalDate) -> RepeatRule? {
        repeatPhrase(in: phrase.split(separator: " ").map(String.init), today: today)?.1
    }

    /// The first `every …` phrase it understands: where it is in the words, its rule and its text.
    static func repeatPhrase(in words: [String], today: LocalDate) -> (Range<Int>, RepeatRule, String)? {
        let lower = words.map { $0.lowercased() }
        for start in lower.indices where lower[start] == "every" {
            var index = start + 1
            var interval = 1
            if index < lower.count, let number = Int(lower[index]), number > 0 {
                interval = number
                index += 1
            }
            guard index < lower.count else { continue }
            let word = lower[index]
            var recurrence: Recurrence?
            switch word {
            case "day", "days": recurrence = Recurrence(.daily, interval: interval)
            case "week", "weeks": recurrence = Recurrence(.weekly, interval: interval)
            case "month", "months": recurrence = Recurrence(.monthly, interval: interval)
            case "year", "years": recurrence = Recurrence(.yearly, interval: interval)
            case "weekday" where interval == 1:
                recurrence = Recurrence(.weekly, byDay: Recurrence.Weekday.weekdays.map { .init($0) })
            default:
                if let weekday = weekdayNames.first(where: { $0.names.contains(word) })?.weekday,
                    let day = Recurrence.Weekday(rawValue: weekday)
                {
                    recurrence = Recurrence(.weekly, interval: interval, byDay: [.init(day)])
                }
            }
            guard let recurrence else { continue }
            let range = start..<(index + 1)
            return (range, RepeatRule(.schedule(recurrence)), words[range].joined(separator: " "))
        }
        return nil
    }
}
