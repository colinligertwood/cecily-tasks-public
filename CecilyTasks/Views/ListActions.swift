import SwiftData
import SwiftUI
import TasksCore

#if os(macOS)
    import AppKit
#endif

/// What a list of item rows does with the selection: a context menu for the selected items (or the
/// one clicked), Return or a double-click to expand one item over the list (on the Mac), Delete to move them to the trash and Escape to clear it.
/// A row with an action, such as the line that shows more events, does it with Return, Space or a double-click instead.
/// When the selected rows leave the list, the row after them is selected (`ListSelection.kept`).
/// On the Mac the list takes the keyboard when a row is clicked, when Return or Escape ends typing
/// in a field, and when it appears or its selection changes while nothing else has the keyboard
/// (`ListKeys.canTakeKeyboard`), and gets the keys in `KeyCommand` pressed on their own in its window (`ListKeys`).
/// A calendar event among the rows has its own menu, and opens the same way. A list whose rows
/// can be moved gives them, by part, to move them from the keyboard and the Item menu.
private struct ItemSelectionActions<Menu: View>: ViewModifier {
    let items: [Item]
    let events: [CalendarEvent]
    /// The rows' selection IDs in the order they're shown, when it isn't the events and then the items.
    let order: [UUID]?
    let arrangeable: [[ListRow]]
    /// Whether the rows can be put in order by hand, which a list sorted otherwise can't.
    let reorders: Bool
    /// Rows that do something when they're chosen, rather than open, by their selection IDs:
    /// the line that shows the rest of a stop's events.
    let actions: [UUID: () -> Void]
    let menu: ([Item]) -> Menu
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool
    #if os(macOS)
        @State private var keys = ListKeys.Target()
    #endif

    private var rowIDs: [UUID] { order ?? events.map(\.selectionID) + items.map(\.id) }

    func body(content: Content) -> some View {
        content
            #if os(macOS)
                .focused($isFocused)
                .background(
                    WindowReader { view in
                        keys.anchor = view
                        keys.window = view.window
                    }
                )
                .onAppear {
                    keys.perform = perform
                    keys.takesArrows = { model.openItem == nil && model.openEvent == nil }
                    keys.stepsStops = { step in
                        guard model.page == .agenda, !model.isReviewing, model.isSearchEmpty else { return false }
                        model.timelineStep = step
                        return true
                    }
                    ListKeys.shared.add(keys)
                    if ListKeys.canTakeKeyboard(in: keys.window ?? NSApp.keyWindow) { isFocused = true }
                }
                .onDisappear { ListKeys.shared.remove(keys) }
                .onChange(of: model.selection) { _, selection in
                    guard !selection.isEmpty else { return }
                    if keys.isBeingClicked || ListKeys.canTakeKeyboard(in: keys.window) { isFocused = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: .doneTyping)) { _ in
                    if model.openItem == nil, model.openEvent == nil { isFocused = true }
                }
            #endif
            .onAppear {
                model.arrangeableRows = arrangeable
                model.arrangeableReorders = reorders
            }
            .onChange(of: arrangeable) { _, rows in model.arrangeableRows = rows }
            .onKeyPress(.space) {
                guard model.selection.count == 1, let id = model.selection.first, let action = actions[id] else { return .ignored }
                action()
                return .handled
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first, actions[id] != nil {
                    EmptyView()
                } else if ids.count == 1, let event = events.first(where: { $0.selectionID == ids.first }) {
                    EventMenu(event: event)
                } else {
                    #if os(macOS)
                        if let id = ids.first {
                            Button(model.showsInspector ? "Hide Inspector" : "Show Inspector") {
                                if !model.showsInspector, !model.selection.contains(id) { model.selection = ids }
                                model.showsInspector.toggle()
                            }
                            .menuKey(KeyCommand.inspector)
                        }
                        if ids.count == 1, let id = ids.first {
                            Button("Open Item") { model.openItem = id }
                        }
                    #endif
                    let chosen = items.filter { ids.contains($0.id) }
                    if ids.count == 1 { Divider() }
                    menu(chosen)
                    if chosen.count == 1, let task = chosen.first, task.bucket != .trash {
                        Divider()
                        Button("New Subtask") { model.newSubtask(of: task) }
                            .menuKey(KeyCommand.newSubtask)
                        AttachmentMenuItems(item: task)
                        if !MarkdownExport.openSubtasks(of: task).isEmpty {
                            Button("Copy Open Subtasks") { model.copyOpenSubtasks(of: task) }
                        }
                        Button("Export as Markdown…") { model.exportMarkdown(task) }
                        if task.isProject, task.status == .open {
                            if task.bucket != .someday {
                                Button("Move to Someday") { model.moveToSomeday(task) }
                                    .menuKey(KeyCommand.toSomeday)
                            }
                            Button("Drop", role: .destructive) { model.drop(task) }
                        }
                    }
                    let repeating = chosen.filter { $0.status == .open && $0.repeatRule != nil }
                    if !repeating.isEmpty, repeating.count == chosen.count {
                        Divider()
                        Button("Skip This One") { model.skip(repeating) }
                    }
                    let startable = chosen.filter { $0.canStart && $0.day(.scheduled) != model.today }
                    let hidable = chosen.count == 1 && chosen.allSatisfy { $0.bucket != .trash }
                    if !startable.isEmpty || hidable { Divider() }
                    if !startable.isEmpty {
                        Button("Schedule for Today") { model.startToday(startable) }
                            .menuKey(KeyCommand.today)
                    }
                    if hidable, let item = chosen.first {
                        Button("Hide Until…") {
                            #if os(macOS)
                                model.selection = [item.id]
                                model.edit(.field(.hideUntil))
                            #else
                                model.hiding = item
                            #endif
                        }
                        .menuKey(KeyCommand.hideUntil)
                        if item.isHidden(today: model.today), item.hideUntil != nil {
                            Button("Show Now") { model.hide(item, until: nil) }
                        }
                    }
                }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first, let action = actions[id] {
                    action()
                } else if ids.count == 1, let event = events.first(where: { $0.selectionID == ids.first }) {
                    model.openEvent = event
                } else {
                    #if os(macOS)
                        if ids.count == 1, let id = ids.first { model.openItem = id }
                    #else
                        if ids.count == 1, let id = ids.first, items.contains(where: { $0.id == id && $0.isProject }) { model.openItem = id }
                    #endif
                }
            }
            .onChange(of: rowIDs) { before, now in
                let kept = ListSelection.kept(model.selection, before: before, now: now)
                if kept != model.selection { model.selection = kept }
            }
            #if os(macOS)
                .onExitCommand { model.selection = [] }
            #endif
    }

    #if os(macOS)
        /// Does what a key pressed on its own asks, such as Delete, or Escape closing the open item
        /// or event; false when it doesn't apply here.
        private func perform(_ command: KeyCommand) -> Bool {
            if command.id == KeyCommand.close.id {
                guard model.openItem != nil || model.openEvent != nil else { return false }
                model.openItem = nil
                model.openEvent = nil
                return true
            }
            guard let action = command.action else { return false }
            let items = model.commandItems
            guard model.can(action, items) else { return false }
            model.perform(action, items)
            return true
        }
    #endif
}

#if os(iOS)
    /// A swipe from the leading edge that starts the row's item today, when it can be and isn't
    /// already.
    private struct StartTodaySwipe: ViewModifier {
        let item: Item
        @Environment(AppModel.self) private var model

        func body(content: Content) -> some View {
            content.swipeActions(edge: .leading) {
                if item.canStart, item.day(.scheduled) != model.today {
                    Button("Schedule for Today", systemImage: "calendar") { model.startToday([item]) }
                        .tint(.teal)
                }
            }
        }
    }

    extension View {
        func startTodaySwipe(_ item: Item) -> some View {
            modifier(StartTodaySwipe(item: item))
        }
    }
#endif

/// A row that can be dragged, with the rest of the selection, as a small tag with its title or
/// how many there are, and that takes dragged rows as its sub-items and files as attachments.
/// It's outlined in the accent colour while they're over it and can go there. `group` is the
/// list's group it's in.
private struct SubItemDragging: ViewModifier {
    let row: ListRow
    let group: DropGroup?
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var isFileTarget = false

    func body(content: Content) -> some View {
        let target = row.item
        let before: Item? = nil
        content
            .draggable(model.dragged(row.item, from: group)) { DragTag(item: row.item, count: draggedCount) }
            .dropDestination(for: String.self) { payloads, _ in
                model.drop(payloads, onto: target, before: before)
            } isTargeted: { over in
                isTargeted = over && model.canDrop(onto: target, before: before)
            }
            .attachmentDrops(onto: target, model: model, isTargeted: $isFileTarget)
            .padding(.horizontal, 6)
            .dropHighlight(isTargeted || isFileTarget, in: RoundedRectangle(cornerRadius: Spacing.small))
            .padding(.horizontal, -6)
    }

    private var draggedCount: Int {
        model.selection.contains(row.item.id) ? model.selection.count : 1
    }
}

/// What a dragged row looks like under the pointer: its circle and title, or a count for several.
private struct DragTag: View {
    let item: Item
    let count: Int

    var body: some View {
        Label(count > 1 ? "\(count) items" : (item.displayTitle), systemImage: "circle")
            .font(.callout)
            .lineLimit(1)
            .frame(maxWidth: 240)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: .capsule)
    }
}

extension DynamicViewContent {
    /// Takes rows dragged between `rows`, shown by the list as a line where they'd go, and puts
    /// them there among the list's items. A project's list, given as `project`, takes them into
    /// it; one of the list's groups, `group`, moves rows from another into it.
    func dropsBetween(_ rows: [ListRow], model: AppModel, project: Item? = nil, group: DropGroup? = nil) -> some DynamicViewContent {
        dropDestination(for: String.self) { payloads, index in
            model.drop(payloads, at: index, in: rows, project: project, into: group)
        }
    }
}

extension View {
    /// Lets the row be dragged onto another to make it a sub-item there; `group` is the list's
    /// group it's in.
    func subItemDragging(_ row: ListRow, group: DropGroup? = nil) -> some View {
        modifier(SubItemDragging(row: row, group: group))
    }

    func itemSelectionActions(
        items: [Item], events: [CalendarEvent] = [], order: [UUID]? = nil, arrangeable: [[ListRow]] = [], reorders: Bool = true,
        actions: [UUID: () -> Void] = [:], @ViewBuilder menu: @escaping ([Item]) -> some View
    ) -> some View {
        modifier(
            ItemSelectionActions(
                items: items, events: events, order: order, arrangeable: arrangeable, reorders: reorders, actions: actions, menu: menu))
    }
}
