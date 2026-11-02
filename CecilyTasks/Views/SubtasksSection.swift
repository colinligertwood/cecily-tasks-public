import SwiftUI
import TasksCore

/// A task's subtasks in its card, above its notes. A line heads it: "Subtasks",
/// how many are done ("2/5"), One at a Time, and a + for a new one; it folds away to just that line, and
/// whether it's folded is kept for each task on the device. Open, it lists the open subtasks in
/// their order, dragged to put them in another, then a new one's draft while its title is typed,
/// then those done, folded. Double-clicking a row opens it (a tap on iPhone), as does its Open
/// action for VoiceOver. Its rows scroll on their own when there are more than fit in `maxHeight`.
struct SubtasksSection: View {
    let task: Item
    let maxHeight: CGFloat
    /// The heading, and what the + makes.
    var title = "Subtasks"
    var newTitle = "New Subtask"
    var offersOneAtATime = true
    @Environment(AppModel.self) private var model
    /// The ids of the tasks whose subtasks are folded, joined by spaces.
    @AppStorage("folded-subtasks") private var foldedIDs = ""
    @State private var showsDone = false
    /// A new subtask being typed.
    @State private var draft: NewItemDraft?
    /// The height the rows need, which the list takes up to `maxHeight`.
    @State private var rowsHeight: CGFloat = 0

    private var subtasks: [Item] {
        (task.children ?? []).filter { $0.bucket != .trash && $0.status != .dropped }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    private var isFolded: Bool {
        (subtasks.isEmpty && draft == nil) || foldedIDs.split(separator: " ").contains(Substring(task.id.uuidString))
    }

    var body: some View {
        let open = subtasks.filter { $0.status == .open }
        let done = subtasks.filter { $0.status == .done }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        VStack(alignment: .leading, spacing: 0) {
            header(done: done.count, total: subtasks.count)
            if !isFolded {
                ScrollView {
                    rows(open: open, done: done)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            rowsHeight = $0
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(rowsHeight, maxHeight))
            }
        }
        .dropDestination(for: String.self) { payloads, _ in model.drop(payloads, onto: task) }
        .takesDraft(for: .card(task.id), into: $draft)
        .onChange(of: draft) { _, draft in
            if draft != nil { setFolded(false) }
        }
    }

    private func header(done: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { setFolded(!isFolded) }
            } label: {
                HStack(spacing: 6) {
                    FoldChevron(isFolded: isFolded)
                        .opacity(total == 0 ? 0 : 1)
                    Text(title)
                        .font(.cardHeading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(total == 0)
            .accessibilityLabel(isFolded ? "Show \(title)" : "Fold \(title)")
            if total > 0 {
                SubtaskCount(tag: RowTag("\(done)/\(total)", symbol: "checklist", spoken: "\(done) of \(total) done"))
            }
            Spacer()
            if total > 1, offersOneAtATime {
                Menu {
                    Toggle(
                        "One at a Time",
                        isOn: Binding(
                            get: { task.isSequential },
                            set: { on in model.edit([task], named: "Change One at a Time") { $0.setSequential(on) } }))
                } label: {
                    Label(task.isSequential ? "One at a Time" : "All at Once", systemImage: task.isSequential ? "list.number" : "list.bullet")
                        .font(.callout)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help(task.isSequential ? "Only the first open subtask is in Actions" : "Every open subtask is in Actions")
            }
            Button(newTitle, systemImage: "plus") {
                setFolded(false)
                if let current = draft, !current.isEmpty { model.make(current) }
                draft = NewItemDraft.subtask(of: task)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(newTitle)
        }
        .padding(.vertical, 6)
    }

    private func rows(open: [Item], done: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(open) { subtask in
                row(subtask)
            }
            DraftRow(draft: $draft)
            if !done.isEmpty {
                DisclosureGroup("Done (\(done.count))", isExpanded: $showsDone) {
                    ForEach(done) { subtask in
                        row(subtask)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func row(_ subtask: Item) -> some View {
        ItemRow(item: subtask, nestedUnder: task)
            .contentShape(Rectangle())
            #if os(macOS)
                .onTapGesture(count: 2) { model.openItem = subtask.id }
            #else
                .onTapGesture { model.openItem = subtask.id }
            #endif
            .draggable(model.dragged(subtask))
            .dropDestination(for: String.self) { payloads, _ in model.drop(payloads, onto: task, before: subtask) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(subtask.displayTitle)
            .accessibilityAction(named: "Open") { model.openItem = subtask.id }
            .contextMenu {
                Button("Open") { model.openItem = subtask.id }
                Button(subtask.status == .done ? "Mark as Not Done" : "Done") { model.toggleDone([subtask]) }
                if subtask.canStart, subtask.day(.scheduled) != model.today {
                    Button("Schedule for Today") { model.startToday([subtask]) }
                }
                Divider()
                Button("Move to Trash", role: .destructive) { model.file([subtask], ClarifyOutcome(.trash)) }
            }
    }

    private func setFolded(_ folded: Bool) {
        var ids = foldedIDs.split(separator: " ").map(String.init).filter { $0 != task.id.uuidString }
        if folded { ids.append(task.id.uuidString) }
        foldedIDs = ids.joined(separator: " ")
    }
}
