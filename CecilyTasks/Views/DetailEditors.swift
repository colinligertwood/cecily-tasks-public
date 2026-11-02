import SwiftData
import SwiftUI
import TasksCore

/// A day typed in quick capture's words ("fri", "tomorrow", "+3d", "2026-11-15") or chosen in a
/// calendar, with Clear. The field has the cursor when it opens, shows the day the words mean, and
/// Return sets it.
struct DayEditor: View {
    let day: LocalDate?
    let set: (LocalDate?) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("fri, tomorrow, +3d", text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($isTyping)
                .onSubmit(setTyped)
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            DatePicker(
                "Day",
                selection: Binding(
                    get: { (day ?? model.today).date(in: .current) },
                    set: { set(LocalDate($0, in: .current)) }),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            Button("Clear") {
                set(nil)
                dismiss()
            }
            .disabled(day == nil)
        }
        .padding()
        .onAppear { isTyping = true }
    }

    private var typedDay: LocalDate? {
        CaptureParser.day(typed.trimmingCharacters(in: .whitespaces).lowercased(), today: model.today)
    }

    /// The day the words mean, or what can be typed.
    private var meaning: String {
        if typed.trimmingCharacters(in: .whitespaces).isEmpty { return "Type a day, or choose one" }
        return typedDay.map(CaptureDraft.format) ?? "Not a day"
    }

    private func setTyped() {
        guard let typedDay else { return }
        set(typedDay)
        dismiss()
    }
}

/// How items repeat: how often and on which days of the calendar, when it ends, and how many days before its date each copy is hidden until, with the rule as a
/// sentence and its next five dates. Repeat sets it on every item, asking first whether a change
/// to an item that repeats already is for this one or all upcoming; Stop Repeating takes it off.
struct RepeatEditor: View {
    let items: [Item]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var choices: RepeatChoices
    /// How many times it happens in all, kept while it has no end.
    @State private var endCount: Int
    /// How many days before its date each copy is hidden until, kept while hiding is off.
    @State private var hideDays: Int
    @State private var isAsking = false

    init(items: [Item], today: LocalDate) {
        self.items = items
        let single = items.count == 1 ? items[0] : nil
        let choices = RepeatChoices(rule: single?.repeatRule?.rule, anchor: single?.repeatBase ?? today)
        _choices = State(initialValue: choices)
        _endCount = State(initialValue: choices.times ?? 10)
        _hideDays = State(initialValue: choices.showDaysBefore > 0 ? choices.showDaysBefore : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                row("Repeats") {
                    Picker("Frequency", selection: $choices.frequency) {
                        Text("Daily").tag(Recurrence.Frequency.daily)
                        Text("Weekly").tag(Recurrence.Frequency.weekly)
                        Text("Monthly").tag(Recurrence.Frequency.monthly)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row("Every", isOn: choices.frequency != .monthly) {
                    number($choices.interval, in: 1...99, then: unit(plural: choices.interval != 1))
                }
                row("On", isOn: choices.frequency == .weekly) { weekdays }
                row("In", isOn: isByMonth, labelAt: UnitPoint(x: 1, y: 0.25)) { months }
                row("On", isOn: isByMonth) {
                    Picker("On", selection: $choices.monthlyBy) {
                        Text("Dates").tag(RepeatChoices.MonthlyBy.days)
                        Text("Day of the Week").tag(RepeatChoices.MonthlyBy.position)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                row("", isOn: isByMonth && choices.monthlyBy == .days) { dates }
                row("The", isOn: isByMonth && choices.monthlyBy == .position) { position }
                GridRow {
                    Divider().gridCellColumns(3)
                }
                row("Ends After", switch: isEnding) {
                    number(endingTimes, in: 1...999, then: endCount == 1 ? "time" : "times") {
                        if let lastDate {
                            Text("last on")
                                .lineLimit(1)
                                .fixedSize()
                            DatePill(day: lastDate)
                        }
                    }
                }
                row("Hide Until", switch: isHiding) {
                    number(hidingDays, in: 1...60, then: hideDays == 1 ? "day before" : "days before")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(rule.summary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                nextDates
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Button("Stop Repeating", role: .destructive) {
                    model.setRepeat(items, nil, text: "")
                    dismiss()
                }
                .disabled(items.allSatisfy { $0.repeatRule == nil })
                Spacer()
                Button("Repeat", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        #if os(macOS)
            .frame(width: 460)
        #endif
        .confirmationDialog("Change this one, or all upcoming?", isPresented: $isAsking) {
            Button("This One") { apply(thisOneOnly: true) }
            Button("All Upcoming") { apply(thisOneOnly: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This One moves only this copy to the new days, and the ones after it repeat as before.")
        }
    }

    /// A row of the form: its label, at `anchor` in its cell, and what it sets, both dimmed and
    /// disabled while `isOn` is false.
    private func row(_ label: String, isOn: Bool = true, labelAt anchor: UnitPoint = .trailing, @ViewBuilder content: () -> some View)
        -> some View
    {
        GridRow {
            Text(label)
                .foregroundStyle(isOn ? .primary : .secondary)
                .gridColumnAlignment(.trailing)
                .gridCellAnchor(anchor)
            Color.clear
                .gridCellUnsizedAxes([.horizontal, .vertical])
            content()
                .disabled(!isOn)
                .foregroundStyle(isOn ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A row turned on and off by a checkbox of its own, in the column between the labels and what
    /// they set.
    private func row(_ label: String, switch isOn: Binding<Bool>, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            Toggle(label, isOn: isOn)
                .labelsHidden()
            content()
                .disabled(!isOn.wrappedValue)
                .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isByMonth: Bool { choices.frequency == .monthly }

    private var rule: RepeatRule { choices.rule }

    /// The items that repeat already, on other days than `rule`'s.
    private var changing: [Item] {
        items.filter { $0.repeatRule?.rule.map { $0.fallsDifferently(from: rule) } ?? false }
    }

    /// The rule as a sentence, and its next five dates for one item.
    private var upcoming: [LocalDate] {
        guard items.count == 1, let item = items.first else { return [] }
        if !changing.isEmpty, let first = rule.firstDate(onOrAfter: model.today) {
            return [first] + rule.upcoming(after: first, count: 4)
        }
        return rule.upcoming(after: item.repeatBase ?? model.today)
    }

    /// The next five dates, each in a pill, as many as fit; or why there are none to show.
    @ViewBuilder private var nextDates: some View {
        let dates = upcoming
        HStack(spacing: 6) {
            if items.count != 1 {
                Text("Each item repeats from its own date.")
            } else if dates.isEmpty {
                Text("It won’t come round again.")
            } else {
                Text("Next")
                ViewThatFits(in: .horizontal) {
                    ForEach((1...dates.count).reversed(), id: \.self) { count in
                        HStack(spacing: 4) {
                            ForEach(dates.prefix(count), id: \.self) { date in
                                DatePill(day: date)
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 22)
    }

    private func save() {
        if changing.isEmpty { apply(thisOneOnly: false) } else { isAsking = true }
    }

    private func apply(thisOneOnly: Bool) {
        let changing = changing
        let rest = items.filter { item in !changing.contains { $0.id == item.id } }
        if !changing.isEmpty { model.changeRepeat(changing, to: rule, text: rule.summary, thisOneOnly: thisOneOnly) }
        if !rest.isEmpty { model.setRepeat(rest, rule, text: rule.summary) }
        dismiss()
    }

    private var weekdays: some View {
        grid(RepeatChoices.weekOrder, columns: 7, of: \.weekdays) { day in
            (Calendar.current.veryShortWeekdaySymbols[day.rawValue - 1], Calendar.current.weekdaySymbols[day.rawValue - 1])
        }
    }

    private var months: some View {
        grid(Array(1...12), columns: 6, of: \.months) { month in
            (Calendar.current.shortMonthSymbols[month - 1], Calendar.current.monthSymbols[month - 1])
        }
    }

    private var dates: some View {
        grid(Array(1...31) + [-1], columns: 8, of: \.monthDays) { day in
            day == -1 ? ("Last", "Last day") : ("\(day)", "Day \(day)")
        }
    }

    /// Buttons for `values`, each on while it's in the choices at `path`, in equal columns.
    private func grid<Value: Hashable>(
        _ values: [Value], columns: Int, of path: WritableKeyPath<RepeatChoices, Set<Value>>, names: @escaping (Value) -> (String, String)
    ) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(values, id: \.self) { value in
                let (short, full) = names(value)
                Toggle(isOn: member(value, of: path)) {
                    Text(short).frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
                .accessibilityLabel(full)
            }
        }
    }

    private var position: some View {
        HStack {
            Picker("The", selection: $choices.position) {
                ForEach(RepeatChoices.positions, id: \.self) { position in
                    Text(positionName(position)).tag(position)
                }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Day", selection: $choices.positionDay) {
                ForEach(RepeatChoices.PositionDay.all, id: \.self) { day in
                    Text(day.name).tag(day)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var isHiding: Binding<Bool> {
        Binding(get: { choices.showDaysBefore > 0 }, set: { choices.showDaysBefore = $0 ? hideDays : 0 })
    }

    private var hidingDays: Binding<Int> {
        Binding(
            get: { hideDays },
            set: {
                hideDays = $0
                choices.showDaysBefore = $0
            })
    }

    private var isEnding: Binding<Bool> {
        Binding(get: { choices.times != nil }, set: { choices.times = $0 ? endCount : nil })
    }

    private var endingTimes: Binding<Int> {
        Binding(
            get: { endCount },
            set: {
                endCount = $0
                choices.times = $0
            })
    }

    /// The day the last time falls on, for one item.
    private var lastDate: LocalDate? {
        thisDate.flatMap { choices.lastDate(times: endCount, from: $0) }
    }

    /// A number to type, right-aligned in room for three digits, its stepper, and `text` after them.
    private func number(
        _ value: Binding<Int>, in range: ClosedRange<Int>, then text: String, @ViewBuilder more: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            NumberField(value: value, range: range)
                .frame(width: 44)
            Stepper("", value: value, in: range)
                .labelsHidden()
            Text(text)
                .lineLimit(1)
            more()
        }
    }

    /// The date of this copy, for one item: the new rule's first date when it moves there, or its own.
    private var thisDate: LocalDate? {
        guard items.count == 1, let item = items.first else { return nil }
        if !changing.isEmpty { return rule.firstDate(onOrAfter: model.today) }
        return item.repeatBase ?? model.today
    }

    private func member<Value: Hashable>(_ value: Value, of path: WritableKeyPath<RepeatChoices, Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { choices[keyPath: path].contains(value) },
            set: { isOn in
                if isOn { choices[keyPath: path].insert(value) } else { choices[keyPath: path].remove(value) }
            })
    }

    private func positionName(_ position: Int) -> String {
        position == -1 ? "Last" : ["First", "Second", "Third", "Fourth", "Fifth"][position - 1]
    }

    private func unit(plural: Bool) -> String {
        switch choices.frequency {
        case .daily: plural ? "days" : "day"
        case .weekly: plural ? "weeks" : "week"
        case .monthly: plural ? "months" : "month"
        case .yearly: plural ? "years" : "year"
        }
    }
}

/// A day in a pill, as the repeat form shows its dates.
private struct DatePill: View {
    let day: LocalDate

    var body: some View {
        Text(CaptureDraft.format(day))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: Capsule())
    }
}

/// Who the item is waiting for, saved when it's done being typed.
struct WaitingForEditor: View {
    let person: String
    let set: (String) -> Void

    var body: some View {
        WaitingForField(person: person, set: set)
            .frame(width: 200)
            .padding()
    }
}

/// A field for who an item is waiting for, suggesting the people items are already waiting for as
/// a name is typed.
struct WaitingForField: View {
    let person: String
    var focusRequest: Binding<Bool>?
    let set: (String) -> Void
    @Query(filter: #Predicate<Item> { $0.waitingOn != nil && $0.bucketRaw != "trash" }) private var waiting: [Item]

    var body: some View {
        let people = WaitingList.people(waiting)
        DoneTypingField("Name", text: person, suggest: { WaitingList.matches($0, among: people) }, focusRequest: focusRequest, save: set)
    }
}

/// The repeating calendar events a meeting's note can be linked to, the linked one ticked, with
/// Unlink; or a way to Settings while calendar events aren't shown.
struct MeetingChoices: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
        let feed = CalendarFeed.shared
        if feed.isShowing {
            let series = feed.series
            if series.isEmpty { Text("No Repeating Events") }
            ForEach(series) { event in
                Toggle(
                    event.displayTitle,
                    isOn: Binding(
                        get: { AgendaEvents.isLinked(item, to: event.seriesID) },
                        set: { model.linkMeeting($0 ? item : nil, to: event.seriesID) }))
            }
        } else {
            SettingsPaneButton(title: "Show Calendar Events…", pane: .calendars)
        }
        if let id = item.calendarEventID {
            Divider()
            Button("Unlink") { model.linkMeeting(nil, to: id) }
        }
    }
}

/// The tasks an item can be made a subtask of: those that already have subtasks and that it can
/// go under, and the one it's under.
struct ProjectChoices: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Item> { $0.statusRaw == "open" && $0.bucketRaw != "trash" }, sort: \Item.title) private var projects: [Item]

    var body: some View {
        Picker(
            "Under",
            selection: Binding(
                get: { item.project?.id },
                set: { id in model.edit([item], named: ItemField.project.undoName) { $0.setProject(projects.first { $0.id == id }) } })
        ) {
            Text("None").tag(UUID?.none)
            Divider()
            ForEach(projects.filter { ($0.isOpenProject && Clarifier.canMake(item, aSubItemOf: $0)) || $0.id == item.project?.id }) { project in
                Text(project.displayTitle).tag(Optional(project.id))
            }
        }
        .pickerStyle(.inline)
    }
}

struct ContextChoices: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Query(sort: \Context.sortOrder) private var contexts: [Context]

    var body: some View {
        ForEach(contexts.filter { !$0.isHidden || has($0) }) { context in
            Toggle(
                isOn: Binding(
                    get: { has(context) },
                    set: { _ in model.edit([item], named: ItemField.contexts.undoName) { $0.toggle(context) } })
            ) {
                Label(context.name, systemImage: context.symbol.isEmpty ? ItemField.contexts.symbol : context.symbol)
            }
        }
    }

    private func has(_ context: Context) -> Bool {
        item.contexts?.contains { $0.id == context.id } ?? false
    }
}

/// The areas, with a checkmark on the item's; choosing it again leaves the item with no area.
struct AreaChoices: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Query(sort: \Area.sortOrder) private var areas: [Area]

    var body: some View {
        ForEach(areas) { area in
            Toggle(
                area.displayName,
                isOn: Binding(
                    get: { item.area?.id == area.id },
                    set: { isOn in model.edit([item], named: ItemField.area.undoName) { $0.setArea(isOn ? area : nil) } })
            )
        }
    }
}

/// A sheet that names a new context or area and gives it to the item.
struct NewRecordSheet: View {
    let item: Item
    let field: ItemField
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .onSubmit(add)
            }
            .formStyle(.grouped)
            .navigationTitle(field.newTitle.replacing("…", with: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(field.addTitle, action: add)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 320, minHeight: 140)
        #endif
    }

    private func add() {
        let context = model.context
        switch field {
        case .contexts:
            guard let made = NewRecord.context(named: name, in: context) else { return }
            model.edit(item) { $0.toggle(made) }
        case .area:
            guard let made = NewRecord.area(named: name, in: context) else { return }
            model.edit(item) { $0.setArea(made) }
        default: return
        }
        dismiss()
    }
}

/// Chooses the day an item comes back on.
struct HideUntilSheet: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date?

    var body: some View {
        NavigationStack {
            DatePicker(
                "Day",
                selection: Binding(get: { day ?? model.today.adding(days: 1).date(in: .current) }, set: { day = $0 }),
                in: model.today.adding(days: 1).date(in: .current)...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding()
            .navigationTitle("Hide Until")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hide") {
                        model.hide(item, until: LocalDate(day ?? model.today.adding(days: 1).date(in: .current), in: .current))
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 320, minHeight: 360)
        #endif
    }
}

/// Asks who items moving to Waiting are waiting for, suggesting the people items are already
/// waiting for, then moves them. A name isn't needed.
struct WaitingForSheet: View {
    let items: [Item]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Item> { $0.waitingOn != nil && $0.bucketRaw != "trash" }) private var waiting: [Item]
    @State private var person = ""
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? "Move to Waiting" : "Move \(items.count) Items to Waiting")
                .font(.headline)
            field
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move", action: move)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        #if os(macOS)
            .frame(width: 320)
        #endif
        .onAppear { isTyping = true }
    }

    @ViewBuilder private var field: some View {
        let typed = TextField("Waiting for", text: $person)
            .textFieldStyle(.roundedBorder)
            .focused($isTyping)
            .onSubmit(move)
        #if os(macOS)
            typed.textInputSuggestions(WaitingList.matches(person, among: WaitingList.people(waiting)), id: \.self) {
                Text($0).textInputCompletion($0)
            }
        #else
            typed
        #endif
    }

    private func move() {
        model.moveToWaiting(items, for: person)
        dismiss()
    }
}
