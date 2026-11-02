import SwiftUI
import TasksCore

/// The app's spacing, from one scale, so the same kind of gap is the same everywhere.
enum Spacing {
    static let hairline: CGFloat = 2
    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let wide: CGFloat = 24

    /// Above and below every list row's content.
    static let rowPadding: CGFloat = 6
    /// Between the tags in a group of details, and between the groups.
    static let tagSpacing: CGFloat = tight
    static let tagGroupSpacing: CGFloat = medium
    /// A card's margins, and the space between its parts.
    static let cardSideMargin: CGFloat = wide
    static let cardTopMargin: CGFloat = 20
    static let cardSpacing: CGFloat = medium
    /// The rounding of a card's corners.
    static let cardCornerRadius: CGFloat = 12
    /// The height of a chip in an index bar (Agenda's timeline, Waiting's letters), and the dot
    /// under one that has something.
    static let indexChipHeight: CGFloat = 32
    static let indexDot: CGFloat = 4
    /// The width of every way of adding to the Inbox on the Mac: the sheet, the quick capture
    /// panel and the menu bar's.
    static let captureWidth: CGFloat = 440
}

extension Font {
    /// An open item's or event's title.
    static let openTitle = Font.title2.weight(.semibold)
    /// The inspector's title.
    static let panelTitle = Font.title3.weight(.semibold)
    /// A part of an open card, such as Subtasks.
    static let cardHeading = Font.headline
    /// Every list row's title, at the system's size.
    static let rowTitle = Font.body
    /// Tags, counts, times, calendars, hints.
    static let detail = Font.callout
    /// The done circle at the start of an item's row.
    static let rowMark = Font.title2.weight(.light)
}

/// The mark at the start of a row, in a column as wide as an item's done circle, so the titles
/// of different kinds of row line up.
struct RowMark<Mark: View>: View {
    @ViewBuilder let mark: Mark

    var body: some View {
        ZStack {
            Image(systemName: "circle")
                .font(.rowMark)
                .hidden()
            mark
        }
    }
}

extension Item {
    /// Its title, or "Untitled" when it has none.
    var displayTitle: String { title.isEmpty ? "Untitled" : title }
}

extension Area {
    /// Its name, or "Untitled" when it has none.
    var displayName: String { name.isEmpty ? "Untitled" : name }
}

/// A label whose symbol takes the same width whatever symbol it is, centred in it, so the names
/// of a column of details start at the same place.
struct DetailLabelStyle: LabelStyle {
    @ScaledMetric private var symbolWidth: CGFloat

    init(symbolWidth: CGFloat = 22) {
        _symbolWidth = ScaledMetric(wrappedValue: symbolWidth, relativeTo: .body)
    }

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .frame(width: symbolWidth)
            configuration.title
        }
    }
}

/// A list's group heading: its name after the symbol of the detail it groups by, which takes the
/// same width whatever it is, so the names of the groups line up.
struct GroupHeading: View {
    let name: String
    let symbol: String

    init(_ name: String, symbol: String) {
        self.name = name
        self.symbol = symbol
    }

    var body: some View {
        Label(name, systemImage: symbol)
            .labelStyle(DetailLabelStyle(symbolWidth: 18))
    }
}

extension View {
    /// Draws it as a card over the list: its background, shadow and outline, and a close button in
    /// its corner that calls `close`. On the Mac, Escape closes it from the list's keys
    /// (`ListKeys`), after a field it's typed in has given up the cursor.
    func cardChrome(close: @escaping () -> Void) -> some View {
        background {
            RoundedRectangle(cornerRadius: Spacing.cardCornerRadius)
                .fill(.background)
                .shadow(color: .black.opacity(0.15), radius: 16, y: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: Spacing.cardCornerRadius).strokeBorder(.separator))
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { close() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close (Esc)")
                .padding(Spacing.medium)
        }
        .padding(Spacing.large)
    }
}

/// A list with nothing to show: a title saying what's missing, a sentence saying what goes
/// there or why it's empty, and an action where there's an obvious one.
struct EmptyList<Actions: View>: View {
    let title: String
    let symbol: String
    let description: String
    @ViewBuilder let actions: Actions

    init(_ title: String, symbol: String, description: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.symbol = symbol
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(description)
        } actions: {
            actions
        }
    }
}

extension EmptyList where Actions == EmptyView {
    init(_ title: String, symbol: String, description: String) {
        self.init(title, symbol: symbol, description: description) { EmptyView() }
    }
}

/// What an open item shows when the item has gone.
struct ItemNotFound: View {
    var body: some View {
        EmptyList("Item Not Found", symbol: "questionmark.circle", description: "It may have been moved or deleted.")
    }
}

extension View {
    /// Marks it as somewhere dragged rows can be dropped while they're over it: the accent colour,
    /// faintly filled behind it and outlined over it, in `shape`.
    func dropHighlight<S: InsettableShape>(_ isTargeted: Bool, in shape: S) -> some View {
        background {
            shape.fill(Color.accentColor.opacity(0.12)).opacity(isTargeted ? 1 : 0)
        }
        .overlay {
            shape.strokeBorder(Color.accentColor, lineWidth: 2).opacity(isTargeted ? 1 : 0)
        }
    }
}

/// The chevron that folds and unfolds what's under something: pointing right when folded, down
/// when open.
struct FoldChevron: View {
    let isFolded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isFolded ? 0 : 90))
    }
}

/// A list's context menu for the chosen items: Done (or Mark as Not Done when they're all done),
/// then Move to Trash, each with its key.
struct DoneAndTrashMenu: View {
    let items: [Item]
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(items.allSatisfy { $0.status == .done } ? "Mark as Not Done" : "Done") { model.toggleDone(items) }
            .menuKey(KeyCommand.done)
        Divider()
        Button("Move to Trash", role: .destructive) { model.file(items, ClarifyOutcome(.trash)) }
            .menuKey(KeyCommand.trash)
    }
}
