import CecilyKit
import SwiftUI
import TasksCore

/// A short fact about a row, shown as a tag: "Calls", "due Fri 23 Oct".
struct RowTag: Identifiable {
    let text: String
    let symbol: String
    var isOverdue = false
    /// Shown lighter than other tags, for a detail that only says why a row is there.
    var isDimmed = false
    /// The text in words, for when the symbol isn't seen: "due Fri 23 Oct" for "Fri 23 Oct".
    var spoken: String
    /// More than the tag says, shown when the pointer rests on it.
    var help: String?

    var id: String { symbol + text }

    init(_ text: String, symbol: String, isOverdue: Bool = false, isDimmed: Bool = false, spoken: String? = nil, help: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.isOverdue = isOverdue
        self.isDimmed = isDimmed
        self.spoken = spoken ?? text
        self.help = help
    }

    init(area: Area) {
        self.init(area.displayName, symbol: ItemField.area.symbol)
    }
}

/// A tag's symbol and text, small and grey, so the title it's under leads: red when it's overdue,
/// and lighter when it's dimmed.
struct TagView: View {
    let tag: RowTag

    var body: some View {
        Label(tag.text, systemImage: tag.symbol)
            .labelStyle(.titleAndIcon)
            .font(.detail)
            .foregroundStyle(tag.isOverdue ? AnyShapeStyle(.problem) : tag.isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .accessibilityLabel(tag.spoken)
            .help(tag.help ?? "")
    }
}

/// What's known about an item, as tags for each field in the row's order, then its marks
/// (attachments).
struct ItemDetails {
    let item: Item
    let today: LocalDate

    /// The field's tags: none when it's empty, otherwise one, with the field's symbol.
    func tags(_ field: ItemField) -> [RowTag] {
        switch field {
        case .due:
            return item.day(.due).map { day in
                let text = CaptureDraft.format(day)
                return [RowTag(text, symbol: field.symbol, isOverdue: day < today, spoken: "due " + text)]
            } ?? []
        case .scheduled:
            return item.day(.scheduled).map { day in
                let text = CaptureDraft.format(day)
                return [RowTag(text, symbol: field.symbol, spoken: "scheduled " + text)]
            } ?? []
        case .hideUntil:
            return item.day(.hideUntil).flatMap { day in
                guard day > today else { return nil }
                let text = CaptureDraft.format(day)
                return [RowTag(text, symbol: field.symbol, isDimmed: true, spoken: "hidden until " + text)]
            } ?? []
        case .repeats:
            return item.repeatRule.map { repetition in
                guard let rule = repetition.rule else { return [RowTag("Repeats", symbol: field.symbol, spoken: "repeats")] }
                return [RowTag(rule.label, symbol: field.symbol, spoken: "repeats " + rule.summary, help: rule.summary)]
            } ?? []
        case .meeting:
            return item.calendarEventID.map { id in
                let text = CalendarFeed.shared.title(ofSeries: id).map { $0.isEmpty ? "Untitled" : $0 } ?? "Calendar Event"
                return [RowTag(text, symbol: field.symbol, spoken: "event " + text)]
            } ?? []
        case .followUp:
            return item.day(.followUp).map { day in
                let text = CaptureDraft.format(day)
                return [RowTag(text, symbol: field.symbol, spoken: "follow up " + text)]
            } ?? []
        case .project:
            return item.project.map { [RowTag($0.displayTitle, symbol: field.symbol)] } ?? []
        case .contexts:
            let names = (item.contexts ?? []).map(\.name).sorted()
            return names.isEmpty ? [] : [RowTag(names.joined(separator: ", "), symbol: field.symbol)]
        case .waitingFor:
            return item.waitingOn.map { [RowTag($0, symbol: field.symbol, spoken: "waiting for \($0)")] } ?? []
        case .area:
            return (item.area ?? item.project?.area).map { [RowTag(area: $0)] } ?? []
        case .timeEstimate:
            return item.timeEstimate.map { [RowTag($0.name, symbol: field.symbol, spoken: "takes " + $0.name)] } ?? []
        case .energy:
            return item.energy.map { [RowTag($0.name, symbol: field.symbol, spoken: $0.name + " energy")] } ?? []
        }
    }

    var marks: [RowTag] {
        var tags: [RowTag] = []
        if let count = item.attachments?.count, count > 0 {
            tags.append(RowTag(count == 1 ? "1 attachment" : "\(count) attachments", symbol: "paperclip"))
        }
        return tags
    }

    /// For an item in the trash, the list Put Back returns it to: "From Someday".
    var trashedFrom: [RowTag] {
        guard item.bucket == .trash else { return [] }
        let list = TrashList.destination(of: item).listName
        return [RowTag("From \(list)", symbol: "arrow.uturn.backward", spoken: "trashed from \(list)")]
    }

    /// "No Next Action" for a task with subtasks, none of them a next step.
    var project: [RowTag] {
        item.isStalled(today: today) ? [RowTag("No Next Action", symbol: "exclamationmark.circle")] : []
    }

    /// How many of the item's subtasks are done, of how many: "2/5". Nil when it has none.
    var subtasks: RowTag? {
        item.subItemCount.map { count in
            let noun = count.total == 1 ? "subtask" : "subtasks"
            return RowTag("\(count.done)/\(count.total)", symbol: "checklist", spoken: "\(count.done) of \(count.total) \(noun) done")
        }
    }

    /// Everything but the area in one line: "Kitchen refit · due Fri 23 Oct · Calls".
    var text: String {
        let order: [ItemField] = [.project, .scheduled, .due, .hideUntil, .repeats, .meeting, .contexts, .waitingFor, .followUp]
        return (order.flatMap(tags) + project + [subtasks].compactMap(\.self) + marks + trashedFrom).map(\.spoken).joined(separator: " · ")
    }
}

extension Bucket {
    /// The name of the list its items are in.
    var listName: String {
        switch self {
        case .inbox: Page.inbox.rawValue
        case .action: Page.actions.rawValue
        case .waiting: Page.waiting.rawValue
        case .someday: Page.someday.rawValue
        case .reference: Page.reference.rawValue
        case .trash: Page.trash.rawValue
        }
    }
}

extension ItemField.Group {
    /// The group's heading in the inspector.
    var name: String {
        switch self {
        case .belongs: "Where It Belongs"
        case .when: "When"
        case .doing: "Doing It"
        case .waiting: "Waiting"
        }
    }
}

extension ItemField {
    /// What an empty field is called in its row.
    var placeholder: String {
        switch self {
        case .due: "Due"
        case .scheduled: "Scheduled"
        case .followUp: "Follow-Up"
        case .hideUntil: "Hide Until"
        case .repeats: "Repeat"
        case .meeting: "Event"
        case .project: "Under"
        case .contexts: "Contexts"
        case .waitingFor: "Waiting"
        case .area: "Area"
        case .timeEstimate: "Time"
        case .energy: "Energy"
        }
    }

    /// What Edit ▸ Undo calls a change to it: "Undo Change Due Date".
    var undoName: String {
        switch self {
        case .due: "Change Due Date"
        case .scheduled: "Change Scheduled Date"
        case .followUp: "Change Follow-Up Date"
        case .hideUntil: "Change Hide Until Date"
        case .repeats: "Change Repeat"
        case .meeting: "Change Event"
        case .project: "Move Under"
        case .contexts: "Change Contexts"
        case .waitingFor: "Change Waiting"
        case .area: "Change Area"
        case .timeEstimate: "Change Time"
        case .energy: "Change Energy"
        }
    }

    /// The menu item that makes a new one, for the details chosen from a list.
    var newTitle: String {
        switch self {
        case .contexts: "New Context…"
        case .area: "New Area…"
        default: ""
        }
    }

    /// The button that adds the new one, in its sheet.
    var addTitle: String {
        switch self {
        case .contexts: "Add Context"
        case .area: "Add Area"
        default: ""
        }
    }

    var symbol: String {
        switch self {
        case .due: "flag"
        case .scheduled: "calendar"
        case .followUp: "bell"
        case .hideUntil: "eye.slash"
        case .repeats: "repeat"
        case .meeting: "calendar.badge.clock"
        case .project: "folder"
        case .contexts: "at"
        case .waitingFor: "hourglass"
        case .area: "circle.grid.2x2"
        case .timeEstimate: "clock"
        case .energy: "bolt"
        }
    }
}

/// An item's details as tags, each opening its editor: those that are set with their value, and
/// with `showsEmpty`, empty ones as their symbol alone. Without it, the area is left out while the
/// lists are narrowed to one. Hide Until is only a row's tag, dimmed, while hidden items are
/// shown. A row nested under another leaves out what's the same as it. Then its marks, and set
/// apart, "No Next Action" when it's stalled.
/// They wrap onto more lines when they don't fit, each group of details kept together.
struct DetailTags: View {
    let item: Item
    var showsEmpty = true
    /// The item of the row it's nested under: details the same as its are left out, and the
    /// Project tag when it's the item's task.
    var nestedUnder: Item?
    @Environment(AppModel.self) private var model
    @State private var editing: ItemField?

    var body: some View {
        let details = ItemDetails(item: item, today: model.today)
        let above = nestedUnder.map { ItemDetails(item: $0, today: model.today) }
        let fields = ItemField.allCases.filter { field in
            if field == .meeting, !item.inspectableFields.contains(field) { return false }
            if field == .hideUntil, showsEmpty || !model.showsHidden { return false }
            if let nestedUnder, field == .project, nestedUnder.id == item.parent?.id { return false }
            if let above, field != .project, details.tags(field).map(\.text) == above.tags(field).map(\.text) { return false }
            return showsEmpty || (!details.tags(field).isEmpty && !(field == .area && model.area != nil))
        }
        let hasTags = !fields.isEmpty || !details.marks.isEmpty
        WrappingLayout(spacing: Spacing.tagSpacing, lineSpacing: Spacing.hairline) {
            ForEach(ItemField.Group.allCases, id: \.self) { group in
                let shown = fields.filter { $0.group == group }
                if !shown.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(shown, id: \.self) { field in
                            FieldTag(item: item, field: field, tags: details.tags(field), editing: $editing)
                        }
                    }
                }
            }
            if !details.marks.isEmpty {
                HStack(spacing: 4) {
                    ForEach(details.marks) { mark in
                        Label(mark.text, systemImage: mark.symbol)
                            .labelStyle(.iconOnly)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .pill(shown: false)
                    }
                }
            }
            if !(details.project + details.trashedFrom).isEmpty {
                HStack(spacing: 4) {
                    if hasTags { SetApart() }
                    ForEach(details.project + details.trashedFrom) { tag in
                        TagView(tag: tag)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.leading, -Pill.inset)
    }
}

/// Lays its views out in a row, left to right, starting a new line when the next doesn't fit.
struct WrappingLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map { $0.width }.max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    /// The views' indices on each line, and each line's width and height.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var lines: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = lines.last, last.width + spacing + size.width <= width {
                lines[lines.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                lines.append(([index], size.width, size.height))
            }
        }
        return lines
    }
}

/// One detail of an item's row: its tags, or a placeholder when it's empty, opening its editor.
private struct FieldTag: View {
    let item: Item
    let field: ItemField
    let tags: [RowTag]
    @Binding var editing: ItemField?
    @Environment(AppModel.self) private var model
    @State private var isCreating = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        editor
            .onHover { isHovering = $0 }
            .focused($isFocused)
            .accessibilityLabel(field.placeholder)
            .accessibilityValue(spokenValue)
    }

    /// The pill around the tag is hidden, except while the pointer is over it, it has the
    /// keyboard, or its editor is open.
    private var isLit: Bool { isHovering || isFocused || editing == field }

    /// What's set, in words, saying when a day has passed: "Fri 23 Oct, overdue".
    private var spokenValue: String {
        tags.map { ($0.help ?? $0.text) + ($0.isOverdue ? ", overdue" : "") }.joined(separator: ", ")
    }

    @ViewBuilder private var editor: some View {
        switch field {
        case .due, .scheduled, .followUp, .hideUntil:
            Button {
                editing = field
            } label: {
                label
            }
            .buttonStyle(.plain)
            .popover(isPresented: isEditing) {
                DayEditor(day: item.day(field)) { day in model.edit([item], named: field.undoName) { $0.setDay(day, for: field) } }
            }
        case .repeats:
            Button {
                editing = field
            } label: {
                label
            }
            .buttonStyle(.plain)
            .popover(isPresented: isEditing) {
                RepeatEditor(items: [item], today: model.today)
            }
        case .meeting:
            Menu {
                MeetingChoices(item: item)
            } label: {
                label
            }
            .tagMenu()
        case .waitingFor:
            Button {
                editing = field
            } label: {
                label
            }
            .buttonStyle(.plain)
            .popover(isPresented: isEditing) {
                WaitingForEditor(person: item.waitingOn ?? "") { person in model.edit(item) { $0.setWaitingFor(person) } }
            }
        case .project:
            Menu {
                if let parent = item.project {
                    Button("Open \(parent.displayTitle)") { model.openItem = parent.id }
                    Divider()
                }
                ProjectChoices(item: item)
            } label: {
                label
            }
            .tagMenu()
        case .contexts:
            Menu {
                ContextChoices(item: item)
                Divider()
                Button(field.newTitle) { isCreating = true }
                SettingsPaneButton(title: "Edit Contexts…", pane: .contexts)
            } label: {
                label
            }
            .tagMenu()
            .sheet(isPresented: $isCreating) { NewRecordSheet(item: item, field: field) }
        case .area:
            Menu {
                AreaChoices(item: item)
                Divider()
                Button(field.newTitle) { isCreating = true }
            } label: {
                label
            }
            .tagMenu()
            .sheet(isPresented: $isCreating) { NewRecordSheet(item: item, field: field) }
        case .timeEstimate:
            Menu {
                Picker(
                    "Time",
                    selection: Binding(
                        get: { item.timeEstimate }, set: { time in model.edit([item], named: field.undoName) { $0.setTimeEstimate(time) } })
                ) {
                    Text("None").tag(TimeEstimate?.none)
                    Divider()
                    ForEach(TimeEstimate.allCases, id: \.self) { Text($0.longName).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
            } label: {
                label
            }
            .tagMenu()
        case .energy:
            Menu {
                Picker(
                    "Energy",
                    selection: Binding(get: { item.energy }, set: { energy in model.edit([item], named: field.undoName) { $0.setEnergy(energy) } })
                ) {
                    Text("None").tag(Energy?.none)
                    Divider()
                    ForEach(Energy.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
            } label: {
                label
            }
            .tagMenu()
        }
    }

    private var label: some View {
        Group {
            if tags.isEmpty {
                Placeholder(field: field)
            } else {
                HStack(spacing: 12) {
                    ForEach(tags) { TagView(tag: $0).fixedSize() }
                }
            }
        }
        .pill(shown: isLit)
    }

    private var isEditing: Binding<Bool> {
        Binding(get: { editing == field }, set: { if !$0, editing == field { editing = nil } })
    }
}

extension View {
    /// A menu drawn as its label alone, for a tag in a row.
    func tagMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// A capsule's outline around a tag, shown or not; it takes the same room either way, and the
/// whole of it can be clicked.
enum Pill {
    static let inset: CGFloat = 8
}

extension View {
    fileprivate func pill(shown: Bool) -> some View {
        padding(.horizontal, Pill.inset)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(.tertiary).opacity(shown ? 1 : 0))
            .contentShape(.capsule)
    }
}

/// An empty detail's symbol, in a lighter grey than a filled one's, named in its tooltip.
private struct Placeholder: View {
    let field: ItemField

    var body: some View {
        Label(field.placeholder, systemImage: field.symbol)
            .labelStyle(.iconOnly)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize()
            .help(field.placeholder)
    }
}

/// The line that sets "No Next Action" apart from the tags before it.
private struct SetApart: View {
    var body: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, 4)
    }
}

/// How many of a task's subtasks are done, of how many: "2/5", with the checklist symbol, in
/// `font`.
struct SubtaskCount: View {
    let tag: RowTag
    var font: Font = .callout

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: tag.symbol)
            Text(tag.text)
        }
        .font(font.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tag.spoken)
    }
}
