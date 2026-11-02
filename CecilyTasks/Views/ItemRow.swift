import SwiftData
import SwiftUI
import TasksCore

/// An item's row: its title, and each detail that's set a tag that opens its editor; the rest are
/// set in the inspector. The start of the notes is under them. While rows just put under it
/// settle, an Undo button at its end puts them back. On the Mac, double-clicking it
/// expands it over the list. On iPhone and iPad the inspector button at its end opens its details,
/// or the details of every selected item when several are. The title is edited in the inspector or
/// the expanded card; a new item's is typed in its draft's row (`DraftRow`). A sub-item's row is
/// indented.
struct ItemRow: View {
    let item: Item
    var isSubItem = false
    /// How many items it's under, which indents it.
    var depth = 0
    /// The item of the row it's nested under, whose details it leaves out.
    var nestedUnder: Item?
    /// How long it's gone unchanged, shown at the row's end in the weekly review.
    var age: String?
    /// The part of the notes shown under it, in place of their start.
    var excerpt: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        let excerpt = excerpt ?? MarkdownText.plain(item.body)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Bullet(isDone: item.status == .done) { model.toggleDone([item]) }
            content(excerpt: excerpt)
            if let age {
                Text(age)
                    .font(.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if model.settling?.task == item.id {
                Button("Undo") { model.undoSettling() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .transition(.opacity)
            }
            #if os(iOS)
                Button("Inspector", systemImage: "info.circle") { model.inspecting = item.id }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.rowTitle)
                    .foregroundStyle(.tertiary)
                    .popover(isPresented: isInspecting, arrowEdge: .trailing) {
                        ItemInspector(item: item)
                            .frame(width: 340)
                    }
            #endif
        }
        .padding(.vertical, Spacing.rowPadding)
        .padding(.leading, CGFloat(max(depth, isSubItem ? 1 : 0)) * Self.subItemIndent)
        .opacity(item.isHidden(today: model.today) ? 0.5 : 1)
        .listRowSeparator(.hidden)
    }

    /// Whether this row's inspector popover is open.
    private var isInspecting: Binding<Bool> {
        Binding(
            get: { model.inspecting == item.id },
            set: { open in
                if open {
                    model.inspecting = item.id
                } else if model.inspecting == item.id {
                    model.inspecting = nil
                }
            })
    }

    /// How far a sub-item's row is indented: past its item's circle.
    static let subItemIndent: CGFloat = 28

    private func content(excerpt: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                titleView
                if let subtasks = ItemDetails(item: item, today: model.today).subtasks {
                    HStack(spacing: 8) {
                        Divider()
                            .frame(height: 18)
                        SubtaskCount(tag: subtasks, font: titleFont)
                    }
                    .fixedSize()
                }
            }
            DetailTags(item: item, showsEmpty: false, nestedUnder: nestedUnder)
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The title; semibold for a task with subtasks.
    private var titleView: some View {
        Text(item.displayTitle)
            .strikethrough(item.status == .done)
            .foregroundStyle(item.title.isEmpty || item.status == .done ? .secondary : .primary)
            .font(titleFont.weight(item.isProject ? .semibold : .regular))
    }

    /// The title's size, the same for a row nested under another.
    private let titleFont: Font = .rowTitle
}

#if os(macOS)
    extension ItemRow {
        /// The narrowest the list beside the sidebar can be: room for a row's circle, a short
        /// title and a few tags.
        static let minimumWidth: CGFloat = 320
    }
#endif

/// The circle at the start of each item's row, a button that marks it done: hollow while it's
/// open, with a checkmark once it's done.
private struct Bullet: View {
    let isDone: Bool
    let action: () -> Void

    var body: some View {
        Button(isDone ? "Mark as Not Done" : "Done", systemImage: isDone ? "checkmark.circle" : "circle", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.rowMark)
            .foregroundStyle(isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }
}
