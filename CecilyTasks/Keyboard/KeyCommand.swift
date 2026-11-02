import SwiftUI
import TasksCore

/// A command's one key, its job, and where the cheat card lists it: a chord, shown beside its menu
/// item; a key typed on its own in a list (Delete); or keys the system handles itself, shown on
/// the card only. Every key the app answers is here, so the menus, the lists and the card can't
/// disagree.
struct KeyCommand: Identifiable {
    /// The card's columns: four jobs, each of whose shortcuts holds the same keys, and the Mac's
    /// standards apart.
    enum Job: String, CaseIterable, Identifiable {
        case navigate = "Navigate"
        case details = "Details"
        case organize = "Organize"
        case view = "View"
        case standard = "Mac standards"

        var id: Self { self }

        /// The keys every shortcut in the job holds; nil when they differ, or are the Mac's
        /// standards.
        var held: EventModifiers? {
            switch self {
            case .navigate, .standard: nil
            case .details: [.shift, .command]
            case .organize: [.control, .command]
            case .view: [.option, .command]
            }
        }
    }

    let id: String
    let name: String
    let job: Job
    /// Its place among its job's groups, which the card separates with a gap.
    var group = 0
    /// The characters the key types, for a key pressed on its own in a list.
    var bare: String?
    var chord: KeyboardShortcut?
    /// The keys the system handles itself, as the card shows them, one per key cap: ["↩"].
    var systemKeys: [String]?
    /// What it does to the items it acts on, for the Item menu's commands.
    var action: ItemAction?
    /// The list it goes to.
    var page: Page?
    /// The detail whose editor it opens in the inspector.
    var detail: DetailRequest?
    /// The keys the card shows in place of the chord's, for a row that stands for several
    /// commands: ["1–9"], or ["↑", "↓"].
    var shownKeys: [String]?
    /// Whether the card has a row of its own for it, rather than sharing another's.
    var isOnCard = true
    /// Whether its chord works only in a list (`ListKeys`), with no shortcut on its menu item.
    var isListOnly = false

    /// All its keys, as the card shows them, one per key cap.
    var keys: [String] {
        if let chord { return Self.caps(chord.modifiers) + (shownKeys ?? [Self.cap(chord.key)]) }
        if let bare { return Self.caps(bare) }
        return systemKeys ?? []
    }

    /// The key tapped, as the card shows it under its job's held keys: the chord without them,
    /// or all its keys when the job holds none.
    var tapped: [String] {
        guard let chord, let held = job.held, chord.modifiers == held else { return keys }
        return shownKeys ?? [Self.cap(chord.key)]
    }

    /// Its keys in words, then its name, as VoiceOver reads its row: "Shift Command H, Hide until".
    var spoken: String {
        keys.map { Self.spokenNames[$0] ?? $0 }.joined(separator: " ") + ", " + name
    }

    /// A key typed on its own: "⌫" for Delete.
    static func caps(_ bare: String) -> [String] {
        bare == deleteKey ? ["⌫"] : [bare.uppercased()]
    }

    /// A chord's caps, its modifiers in the Mac's order and then its key: "⇧", "⌘" and "N".
    static func caps(_ chord: KeyboardShortcut) -> [String] {
        caps(chord.modifiers) + [cap(chord.key)]
    }

    /// Modifier keys' caps, in the Mac's order: "⌃", "⌥", "⇧", "⌘".
    static func caps(_ modifiers: EventModifiers) -> [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        return caps
    }

    private static func cap(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: "↩"
        case .delete: "⌫"
        case .escape: "esc"
        case .space: "Space"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        default: String(key.character).uppercased()
        }
    }

    static func label(_ chord: KeyboardShortcut) -> String { caps(chord).joined() }

    /// What the modifier keys' symbols stand for, as the card's legend shows them.
    static let legend: [(symbol: String, name: String)] = [("⌘", "Command"), ("⇧", "Shift"), ("⌥", "Option"), ("⌃", "Control")]

    /// Every symbol on the card in words, for VoiceOver.
    static let spokenNames: [String: String] = Dictionary(uniqueKeysWithValues: legend.map { ($0.symbol, $0.name) }).merging([
        "↩": "Return", "⌫": "Delete", "esc": "Escape", "↑": "Up", "↓": "Down", "←": "Left", "→": "Right",
    ]) { first, _ in first }

    /// The command whose key, pressed on its own, typed `characters`; nil while ⌘, ⌥ or ⌃ is held.
    static func bare(_ characters: String, modifiers: EventModifiers) -> KeyCommand? {
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        return all.first { $0.bare == characters }
    }

    /// The command that works only in a list whose chord is `key` with `modifiers`.
    static func listOnly(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyCommand? {
        all.first { $0.isListOnly && $0.chord?.key == key && $0.chord?.modifiers == modifiers }
    }

    /// The command that opens `request`'s editor in the inspector.
    static func opening(_ request: DetailRequest) -> KeyCommand? {
        all.first { $0.detail == request }
    }

    /// The commands the card lists, in its order.
    static var onCard: [KeyCommand] { all.filter(\.isOnCard) }
}

extension KeyCommand {
    /// The lists, by their number in the sidebar: ⌘1 for Agenda to ⌘7 for Trash.
    static let lists: [KeyCommand] = Page.allCases.enumerated().map { index, page in
        KeyCommand(
            id: "go-\(page.rawValue)", name: page.rawValue, job: .navigate,
            chord: KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))), page: page)
    }
    static let upDown = KeyCommand(id: "upDown", name: "Next, previous", job: .navigate, group: 1, systemKeys: ["↑", "↓"])
    static let open = KeyCommand(id: "open", name: "Open", job: .navigate, group: 1, systemKeys: ["↩"])
    static let close = KeyCommand(id: "close", name: "Close", job: .navigate, group: 1, systemKeys: ["esc"])
    static let earlierLater = KeyCommand(id: "earlierLater", name: "Earlier, later", job: .navigate, group: 1, systemKeys: ["←", "→"])

    static let title = detail("Title", .title, "e", group: 0)
    static let area = detail("Area", .field(.area), "a", group: 1)
    static let task = detail("Task", .field(.project), "u", group: 1)
    static let scheduled = detail("Scheduled", .field(.scheduled), "s", group: 2)
    static let due = detail("Due", .field(.due), "d", group: 2)
    static let repeats = detail("Repeat", .field(.repeats), "r", group: 2)
    static let hideUntil = detail("Hide until", .field(.hideUntil), "h", group: 2)
    static let contexts = detail("Contexts", .field(.contexts), "k", group: 3)
    static let time = detail("Time", .field(.timeEstimate), "t", group: 3)
    static let energy = detail("Energy", .field(.energy), "y", group: 3)
    static let waitingFor = detail("Waiting for", .field(.waitingFor), "p", group: 4)
    static let followUp = detail("Follow up", .field(.followUp), "f", group: 4)

    /// A detail's editor in the inspector: ⇧⌘ and a letter.
    private static func detail(_ name: String, _ request: DetailRequest, _ letter: Character, group: Int) -> KeyCommand {
        KeyCommand(
            id: "detail-\(name)", name: name, job: .details, group: group,
            chord: KeyboardShortcut(KeyEquivalent(letter), modifiers: [.shift, .command]),
            detail: request)
    }
    static let newSubtask = KeyCommand(
        id: "newSubtask", name: "New subtask", job: .details, group: 5, chord: KeyboardShortcut("n", modifiers: [.shift, .command]))

    static let toActions = move(.action, "3")
    static let toWaiting = move(.waiting, "4")
    static let toSomeday = move(.someday, "5")
    static let toReference = move(.reference, "6")
    static let today = KeyCommand(
        id: "today", name: "Today", job: .organize, group: 1, chord: KeyboardShortcut("t", modifiers: organizing), action: .today)
    static let done = KeyCommand(
        id: "done", name: "Done", job: .organize, group: 1, chord: KeyboardShortcut("k", modifiers: organizing), action: .done)
    static let moveUp = arrange("Up, down", .up, .upArrow, shownKeys: ["↑", "↓"])
    static let moveDown = arrange("Down", .down, .downArrow, isOnCard: false)
    static let intoAbove = arrange("Into task above", .intoAbove, .rightArrow)
    static let outOfTask = arrange("Out of its task", .outOfTask, .leftArrow)

    /// The keys Organize's shortcuts hold.
    private static let organizing: EventModifiers = [.control, .command]

    /// Moving the selected rows: ⌃⌘ and an arrow, in a list only.
    private static func arrange(
        _ name: String, _ move: Arrangement, _ key: KeyEquivalent, shownKeys: [String]? = nil, isOnCard: Bool = true
    ) -> KeyCommand {
        KeyCommand(
            id: "arrange-\(move)", name: name, job: .organize, group: 2, chord: KeyboardShortcut(key, modifiers: organizing),
            action: .arrange(move),
            shownKeys: shownKeys, isOnCard: isOnCard, isListOnly: true)
    }

    /// Moving to a list: ⌃⌘ with the list's number.
    private static func move(_ bucket: Bucket, _ number: Character) -> KeyCommand {
        KeyCommand(
            id: "to-\(bucket.rawValue)", name: bucket.title, job: .organize,
            chord: KeyboardShortcut(KeyEquivalent(number), modifiers: organizing), action: .move(bucket))
    }

    static let inspector = KeyCommand(id: "inspector", name: "Inspector", job: .view, chord: KeyboardShortcut("i", modifiers: [.option, .command]))
    /// The first nine areas, in Settings' order: ⌥⌘ and the area's number, shown on the card as one row.
    static let areas = KeyCommand(
        id: "areas", name: "Area", job: .view, chord: KeyboardShortcut("1", modifiers: [.option, .command]), shownKeys: ["1–9"])
    static let allAreas = KeyCommand(id: "allAreas", name: "All areas", job: .view, chord: KeyboardShortcut("0", modifiers: [.option, .command]))

    /// The shortcut for the area numbered `number` (1 to 9) in Settings' order.
    static func area(_ number: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: areas.chord?.modifiers ?? [.option, .command])
    }

    /// What the Delete key types.
    static let deleteKey = "\u{7F}"

    static let newItem = KeyCommand(id: "newItem", name: "New item", job: .standard, chord: KeyboardShortcut("n"))
    static let search = KeyCommand(id: "search", name: "Search", job: .standard, chord: KeyboardShortcut("f"))
    static let back = KeyCommand(id: "back", name: "Back", job: .standard, chord: KeyboardShortcut("["))
    static let sidebar = KeyCommand(id: "sidebar", name: "Sidebar", job: .standard, chord: KeyboardShortcut("s", modifiers: [.control, .command]))
    static let undo = KeyCommand(id: "undo", name: "Undo", job: .standard, systemKeys: ["⌘", "Z"])
    static let trash = KeyCommand(id: "trash", name: "Trash", job: .standard, bare: deleteKey, action: .trash)
    static let card = KeyCommand(id: "card", name: "This card", job: .standard, chord: KeyboardShortcut("?"))

    /// In the card's order: each job's commands by group, then the Mac's standards.
    static let all: [KeyCommand] =
        lists + [
            upDown, open, close, earlierLater,
            title, area, task, scheduled, due, repeats, hideUntil, contexts, time, energy, waitingFor, followUp, newSubtask,
            toActions, toWaiting, toSomeday, toReference, today, done, moveUp, moveDown, intoAbove, outOfTask,
            inspector, areas, allAreas,
            newItem, search, back, sidebar, undo, trash, card,
        ]
}

extension View {
    /// The command's key, shown beside a context menu's item: its chord, or Delete for the key
    /// pressed on its own.
    @ViewBuilder func menuKey(_ command: KeyCommand) -> some View {
        if command.bare == KeyCommand.deleteKey { keyboardShortcut(.delete, modifiers: []) } else { keyboardShortcut(command) }
    }

    /// The command's chord, when it has one and it works outside lists.
    @ViewBuilder func keyboardShortcut(_ command: KeyCommand?) -> some View {
        if let command, let chord = command.chord, !command.isListOnly { keyboardShortcut(chord) } else { self }
    }
}

/// Whether the app shows its keys beside what they do: the sidebar's caps, the inspector's chords
/// and the keys in tooltips (View ▸ Show Keyboard Shortcuts). The menus and the key card always
/// show them.
enum KeyHints {
    static let key = "shows-key-hints"
}
