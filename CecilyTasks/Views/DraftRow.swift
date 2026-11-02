import SwiftUI
import TasksCore

/// A new item's row while its title is typed, with the cursor in it, held by the view it was
/// started in and seen by no other. Return makes the item and starts another in the same place;
/// the title losing the cursor, or the row going, makes it too; Escape drops it. An empty one is
/// dropped. Nothing shows while there's no draft.
struct DraftRow: View {
    @Binding var draft: NewItemDraft?
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        if draft != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle")
                    .font(.rowMark)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                TextField("Title", text: title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.rowTitle)
                    .focused($isFocused)
                    .onSubmit { finish(startingAnother: true) }
                    .onKeyPress(.escape) {
                        draft = nil
                        return .handled
                    }
            }
            .padding(.vertical, Spacing.rowPadding)
            .listRowSeparator(.hidden)
            .task { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused { finish(startingAnother: false) }
            }
            .onDisappear { finish(startingAnother: false) }
        }
    }

    /// The title typed, with a line break taken as Return.
    private var title: Binding<String> {
        Binding(
            get: { draft?.title ?? "" },
            set: { typed in
                if typed.contains("\n") {
                    draft?.title = typed.replacing("\n", with: "")
                    finish(startingAnother: true)
                } else {
                    draft?.title = typed
                }
            })
    }

    /// Makes the item for the draft, if it has a title, and ends it. The next draft starts as a new
    /// row once the list has its new item, so it takes the cursor as it appears.
    private func finish(startingAnother: Bool) {
        guard let current = draft else { return }
        draft = nil
        guard !current.isEmpty else { return }
        model.make(current)
        if startingAnother {
            Task { draft = NewItemDraft(current.place) }
        }
    }
}

extension View {
    /// A list's new item: its draft's row above the list's rows, kept apart from them so the list
    /// changing doesn't take its cursor, and the drafts New Item asks `target` to start.
    func listDraft(for target: DraftRequest.Target, into draft: Binding<NewItemDraft?>) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            DraftRow(draft: draft)
                .padding(.horizontal, Spacing.large)
                .background(.background)
        }
        .takesDraft(for: target, into: draft)
    }

    /// Takes into `draft` a draft that New Item or New Subtask asks `target` to start, when the
    /// view appears and whenever one's asked for, first making the item for any draft already
    /// typed.
    func takesDraft(for target: DraftRequest.Target, into draft: Binding<NewItemDraft?>) -> some View {
        modifier(TakesDraft(target: target, draft: draft))
    }
}

private struct TakesDraft: ViewModifier {
    let target: DraftRequest.Target
    @Binding var draft: NewItemDraft?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onAppear(perform: take)
            .onChange(of: model.draftRequest) { take() }
    }

    private func take() {
        guard let taken = model.takeDraft(for: target) else { return }
        if let current = draft, !current.isEmpty { model.make(current) }
        draft = taken
    }
}
