import SwiftData
import SwiftUI
import TasksCore
import UniformTypeIdentifiers

/// An open task: a way back to the task it's a subtask of, its
/// title and details, its subtasks, its attachments, then its notes filling the rest. With
/// `focusesNotes`, the cursor goes in the notes when it opens. Files dropped on it, or pasted on
/// the Mac, are added as attachments.
struct OpenTaskContent: View {
    let item: Item
    var focusesNotes = false
    @Environment(AppModel.self) private var model
    @AppStorage(KeyHints.key) private var showsKeyHints = true
    @State private var height: CGFloat = 600
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cardSpacing) {
            if let parent = item.parent {
                Button {
                    model.back()
                } label: {
                    Label(parent.displayTitle, systemImage: "chevron.left")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .help(showsKeyHints ? "Back to \(parent.displayTitle) (⌘[)" : "Back to \(parent.displayTitle)")
                .accessibilityLabel("Back to \(parent.displayTitle)")
            }
            DoneTypingField("Title", text: item.title, axis: .vertical) { title in
                model.edit([item], named: "Change Title") { $0.setTitle(title.replacing("\n", with: " ")) }
            }
            .id(item.id)
            .textFieldStyle(.plain)
            .font(.openTitle)
            .padding(.trailing, Spacing.wide)
            DetailTags(item: item)
            SubtasksSection(task: item, maxHeight: min(height / 3, 240))
            AttachmentsSection(item: item)
            Divider()
            ItemNotes(container: model.container, item: item, focusesOnOpen: focusesNotes)
                .id(item.id)
        }
        .attachmentDrops(onto: item, model: model, isTargeted: $isDropTarget)
        .dropHighlight(isDropTarget, in: RoundedRectangle(cornerRadius: Spacing.small).inset(by: -Spacing.small))
        #if os(macOS)
            .onPasteCommand(of: [.fileURL, .image, .pdf]) { providers in model.attach(providers, to: item) }
        #endif
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            height = $0
        }
    }
}

/// An item expanded over the list on the Mac, as a floating card, across its width. Escape or its
/// close button closes it.
struct ItemCard: View {
    @Environment(AppModel.self) private var model
    @Query private var found: [Item]

    init(itemID: UUID) {
        _found = Query(filter: #Predicate<Item> { $0.id == itemID })
    }

    var body: some View {
        Group {
            if let item = found.first {
                OpenTaskContent(item: item, focusesNotes: true)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            } else {
                ItemNotFound()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardChrome { model.openItem = nil }
    }
}
