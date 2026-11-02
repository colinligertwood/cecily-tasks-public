import SwiftData
import SwiftUI
import TasksCore

/// An item's notes, as Markdown in the Markdown editor, filling the space it's given, saved as
/// they're typed. With `focusesOnOpen`, the cursor goes in them when they open. Files pasted or
/// dropped into them are added to the item as attachments.
struct ItemNotes: View {
    let item: Item
    let focusesOnOpen: Bool
    @Environment(AppModel.self) private var model
    @State private var draft: NoteDraft

    init(container: ModelContainer, item: Item, focusesOnOpen: Bool = false) {
        self.item = item
        self.focusesOnOpen = focusesOnOpen
        _draft = State(initialValue: NoteDraft(container: container, itemID: item.id))
    }

    var body: some View {
        NotesEditor(draft: draft, focusesOnOpen: focusesOnOpen) { files in model.attach(files, to: item) }
    }
}

/// The notes of the note in Reference linked to an event's series. With none
/// linked, they're empty, and the first time there's something to save they make one, named like
/// the event and linked to it. A note linked to the event while it's open takes their place.
struct EventItemNotes: View {
    let event: CalendarEvent
    let focusesOnOpen: Bool
    private let container: ModelContainer
    @Query(filter: #Predicate<Item> { $0.bucketRaw == "reference" && $0.statusRaw == "open" }) private var notes: [Item]
    @State private var draft: NoteDraft

    init(container: ModelContainer, event: CalendarEvent, focusesOnOpen: Bool = false) {
        self.event = event
        self.focusesOnOpen = focusesOnOpen
        self.container = container
        let notes = (try? ModelContext(container).fetch(FetchDescriptor<Item>())) ?? []
        _draft = State(initialValue: Self.draft(for: AgendaEvents.linkedNote(for: event, in: notes)?.id, event: event, container: container))
    }

    var body: some View {
        NotesEditor(draft: draft, focusesOnOpen: focusesOnOpen, placeholder: "Notes")
            .onChange(of: AgendaEvents.linkedNote(for: event, in: notes)?.id) { _, id in
                guard id != draft.itemID else { return }
                draft.save()
                draft = Self.draft(for: id, event: event, container: container)
            }
    }

    private static func draft(for noteID: UUID?, event: CalendarEvent, container: ModelContainer) -> NoteDraft {
        if let noteID { return NoteDraft(container: container, itemID: noteID) }
        return NoteDraft(container: container) { context in AgendaEvents.newMeetingNote(for: event, in: context).note }
    }
}

/// Notes in the Markdown editor, filling the space they're given, with why they couldn't be saved
/// under them when they couldn't, saved when the editor goes.
private struct NotesEditor: View {
    let draft: NoteDraft
    let focusesOnOpen: Bool
    var placeholder: String?
    var takeFiles: (([PastedFile]) -> Void)?
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = draft
        MarkdownWebEditor(
            text: $draft.text, focusesOnOpen: focusesOnOpen, placeholder: placeholder, links: model, noteID: draft.itemID, takeFiles: takeFiles
        )
        .safeAreaInset(edge: .bottom) {
            if let problem = draft.problem {
                Text(problem).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
        .onDisappear { draft.save() }
    }
}
