import SwiftData
import SwiftUI
import TasksCore

/// The inspector beside the list on the Mac: the details of the selected items, or a note that
/// nothing is selected. It fills its column, whatever its contents.
struct SelectionInspector: View {
    @Environment(AppModel.self) private var model
    @Query private var items: [Item]

    var body: some View {
        let selected = items.filter { model.selection.contains($0.id) }
        let event = model.selection.count == 1 ? model.selection.first.flatMap(CalendarFeed.shared.event(withSelectionID:)) : nil
        Group {
            if let event, selected.isEmpty {
                EventInspector(event: event)
            } else if selected.isEmpty {
                EmptyList("No Selection", symbol: "info.circle", description: "Select an item or event to see its details.")
            } else {
                DetailsForm(items: selected)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

/// The inspector opened from a row: the item's details, or every selected item's when it's one of
/// several selected.
struct ItemInspector: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Item> { $0.statusRaw == "open" }) private var open: [Item]

    var body: some View {
        let selected = open.filter { model.selection.contains($0.id) }
        DetailsForm(items: selected.count > 1 && selected.contains { $0.id == item.id } ? selected : [item])
    }
}

/// The details of one or more items: every detail, wherever they are, under its group's heading,
/// showing their value when they share one and "Mixed" when they don't, and a change sets it on
/// every item. One item also has its title and who it's waiting for, saved when they're done being
/// typed. Notes are on the item's own page. A detail asked for from the keyboard
/// (`AppModel.detailRequest`) opens its editor, or puts the cursor in its field.
private struct DetailsForm: View {
    let items: [Item]
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Item> { $0.statusRaw == "open" && $0.bucketRaw != "trash" }, sort: \Item.title) private var projects: [Item]
    @Query(sort: \Context.sortOrder) private var contexts: [Context]
    @Query(sort: \Area.sortOrder) private var areas: [Area]
    @State private var editingDay: ItemField?
    @State private var focusesTitle = false
    @State private var focusesWaitingFor = false

    var body: some View {
        Form {
            if let item = single {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        #if os(macOS)
                            DetailLabel(name: "Title", symbol: "textformat", request: .title)
                        #endif
                        DoneTypingField("Title", text: item.title, axis: .vertical, focusRequest: $focusesTitle) { title in
                            model.edit([item], named: "Change Title") { $0.setTitle(title) }
                        }
                        .id(item.id)
                        .font(.panelTitle)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if item.bucket == .trash {
                    Section {
                        LabeledContent {
                            Text(TrashList.destination(of: item).listName)
                        } label: {
                            Label("Trashed From", systemImage: "arrow.uturn.backward")
                                .labelStyle(DetailLabelStyle())
                        }
                    }
                }
            }
            details
        }
        .formStyle(.grouped)
        .onChange(of: model.detailRequest, initial: true) { _, request in
            guard let request else { return }
            model.detailRequest = nil
            switch request {
            case .title: focusesTitle = true
            case .field(.waitingFor): focusesWaitingFor = true
            case .field(let field): editingDay = field
            }
        }
    }

    /// Shows its editor in a popover while `field` is being edited.
    private func editing(_ field: ItemField) -> Binding<Bool> {
        Binding(get: { editingDay == field }, set: { if !$0 { editingDay = nil } })
    }

    @ViewBuilder private var details: some View {
        if single == nil {
            Section {
                Text("\(items.count) Items")
                    .font(.panelTitle)
            }
        }
        ForEach(ItemField.Group.allCases, id: \.self) { group in
            let shown = group.fields.filter(fields.contains)
            if !shown.isEmpty {
                Section(group.name) {
                    ForEach(shown, id: \.self) { field in
                        LabeledContent {
                            control(field)
                        } label: {
                            DetailLabel(name: field.placeholder, symbol: field.symbol, request: .field(field))
                        }
                    }
                }
            }
        }
    }

    private var single: Item? { items.count == 1 ? items.first : nil }

    private var fields: [ItemField] {
        ItemField.allCases.filter { field in
            (![.waitingFor, .meeting].contains(field) || single != nil) && items.allSatisfy { $0.inspectableFields.contains(field) }
        }
    }

    @ViewBuilder private func control(_ field: ItemField) -> some View {
        switch field {
        case .due, .scheduled, .followUp, .hideUntil:
            let shared = Shared(items) { $0.day(field) }
            Button(text(shared) { $0.map(CaptureDraft.format) ?? "None" }) { editingDay = field }
                .popover(isPresented: editing(field)) {
                    DayEditor(day: shared.flatMap { if case .same(let day) = $0 { day } else { nil } } ?? nil) { day in
                        apply(field) { $0.setDay(day, for: field) }
                    }
                }
        case .repeats:
            Button(text(Shared(items) { $0.repeatRule.map { $0.rule?.label ?? "Repeats" } }) { $0 ?? "None" }) {
                editingDay = field
            }
            .help(single?.repeatRule?.rule?.summary ?? "")
            .popover(isPresented: editing(field)) {
                RepeatEditor(items: items, today: model.today)
            }
        case .meeting:
            if let item = single {
                Menu(ItemDetails(item: item, today: model.today).tags(field).first?.text ?? "None") {
                    MeetingChoices(item: item)
                }
                .fixedSize()
            }
        case .project:
            Button(text(Shared(items) { $0.project?.title }) { $0 ?? "None" }) { editingDay = field }
                .popover(isPresented: editing(field)) {
                    let candidates = projects.filter { project in
                        project.isOpenProject && items.allSatisfy { Clarifier.canMake($0, aSubItemOf: project) || $0.parent?.id == project.id }
                    }
                    ChoiceList(
                        choices: [none(field, isOn: items.allSatisfy { $0.project == nil }) { $0.setProject(nil) }]
                            + candidates.map { project in
                                ChoiceList.Choice(
                                    id: project.id.uuidString, name: project.displayTitle,
                                    isOn: items.allSatisfy { $0.project?.id == project.id }
                                ) { apply(field) { $0.setProject(project) } }
                            })
                }
        case .contexts:
            Button(text(Shared(items) { ($0.contexts ?? []).map(\.name).sorted() }) { $0.isEmpty ? "None" : $0.joined(separator: ", ") }) {
                editingDay = field
            }
            .popover(isPresented: editing(field)) {
                ChoiceList(
                    choices: contexts.filter { !$0.isHidden }.map { context in
                        let has = items.allSatisfy { $0.contexts?.contains { $0.id == context.id } ?? false }
                        return ChoiceList.Choice(id: context.id.uuidString, name: context.name, isOn: has) {
                            apply(field) { $0.setContext(context, !has) }
                        }
                    }, keepsOpen: true)
            }
        case .area:
            Button(text(Shared(items) { $0.area?.name }) { $0 ?? "None" }) { editingDay = field }
                .popover(isPresented: editing(field)) {
                    ChoiceList(
                        choices: [none(field, isOn: items.allSatisfy { $0.area == nil }) { $0.setArea(nil) }]
                            + areas.map { area in
                                ChoiceList.Choice(id: area.id.uuidString, name: area.displayName, isOn: items.allSatisfy { $0.area?.id == area.id }) {
                                    apply(field) { $0.setArea(area) }
                                }
                            })
                }
        case .timeEstimate:
            Button(text(Shared(items) { $0.timeEstimate }) { $0?.longName ?? "None" }) { editingDay = field }
                .popover(isPresented: editing(field)) {
                    ChoiceList(
                        choices: [none(field, isOn: items.allSatisfy { $0.timeEstimate == nil }) { $0.setTimeEstimate(nil) }]
                            + TimeEstimate.allCases.map { time in
                                ChoiceList.Choice(id: time.rawValue, name: time.longName, isOn: items.allSatisfy { $0.timeEstimate == time }) {
                                    apply(field) { $0.setTimeEstimate(time) }
                                }
                            })
                }
        case .energy:
            Button(text(Shared(items) { $0.energy }) { $0?.name ?? "None" }) { editingDay = field }
                .popover(isPresented: editing(field)) {
                    ChoiceList(
                        choices: [none(field, isOn: items.allSatisfy { $0.energy == nil }) { $0.setEnergy(nil) }]
                            + Energy.allCases.map { energy in
                                ChoiceList.Choice(id: energy.rawValue, name: energy.name, isOn: items.allSatisfy { $0.energy == energy }) {
                                    apply(field) { $0.setEnergy(energy) }
                                }
                            })
                }
        case .waitingFor:
            if let item = single {
                WaitingForField(person: item.waitingOn ?? "", focusRequest: $focusesWaitingFor) { person in
                    model.edit(item) { $0.setWaitingFor(person) }
                }
                .id(item.id)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
            }
        }
    }

    private func text<Value>(_ shared: Shared<Value>?, _ describe: (Value) -> String) -> String {
        switch shared {
        case .same(let value): describe(value)
        case .mixed: "Mixed"
        case nil: ""
        }
    }

    /// The choice of none, which `clear` sets.
    private func none(_ field: ItemField, isOn: Bool, _ clear: @escaping (Item) -> Void) -> ChoiceList.Choice {
        ChoiceList.Choice(id: "none", name: "None", isOn: isOn) { apply(field, clear) }
    }

    private func apply(_ field: ItemField, _ change: (Item) -> Void) {
        model.edit(items, named: field.undoName, change)
    }
}

/// A detail's name with its symbol and, on the Mac while key hints are shown, the chord that opens
/// its editor, as menus show it: "Due ⇧⌘D", on one line.
private struct DetailLabel: View {
    let name: String
    let symbol: String
    let request: DetailRequest
    @AppStorage(KeyHints.key) private var showsKeyHints = true

    var body: some View {
        Label {
            HStack(spacing: Spacing.small) {
                Text(name)
                #if os(macOS)
                    if showsKeyHints, let chord = KeyCommand.opening(request)?.chord {
                        Text(KeyCommand.label(chord))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                #endif
            }
        } icon: {
            Image(systemName: symbol)
        }
        .labelStyle(DetailLabelStyle())
        .lineLimit(1)
        .fixedSize()
    }
}
