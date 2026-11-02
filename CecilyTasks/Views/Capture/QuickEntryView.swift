#if os(macOS)
    import SwiftData
    import SwiftUI
    import TasksCore

    /// What's been typed into quick entry and the details chosen for it, kept while the panel
    /// is closed until it's added or cancelled.
    @MainActor
    @Observable
    final class QuickEntryDraft {
        var text = ""
        var details = CaptureDetails()
        /// How many times the panel's been shown, which its appearing follows.
        var shows = 0

        func clear() {
            text = ""
            details = CaptureDetails()
        }

        /// Adds the item to the Inbox and clears it for the next, when its first line has a title.
        func add(to model: AppModel) {
            guard model.add(entry: text, details: details) else { return }
            clear()
        }
    }

    /// Quick entry on the Mac: the Markdown editor, over a large Inbox symbol, its first line the item's
    /// title and the lines after it its notes, and below it the details it can be given, in the
    /// inspector's groups. A detail chosen here, as a value or as None, wins over the one the first
    /// line's tokens name, which each column shows as they're typed; the area is the lists' until
    /// another's chosen. Each detail's editor opens with the key that
    /// opens it in the inspector. ⌘Return adds it to the Inbox and clears it for the next; Escape
    /// clears it and closes.
    struct QuickEntryView: View {
        let draft: QuickEntryDraft
        let close: () -> Void
        @Environment(AppModel.self) private var model
        @Query(sort: \Area.sortOrder) private var areas: [Area]
        @Query(sort: \Context.sortOrder) private var contexts: [Context]
        @Query(filter: #Predicate<Item> { $0.bucketRaw == "inbox" && $0.statusRaw == "open" }) private var inbox: [Item]
        @Query(filter: #Predicate<Item> { $0.statusRaw == "open" }) private var openItems: [Item]
        @State private var editing: ItemField?
        @AppStorage(KeyHints.key) private var showsKeyHints = true

        static let width: CGFloat = 680
        private static let repeats = ["every day", "every weekday", "every week", "every 2 weeks", "every month", "every year"]

        var body: some View {
            @Bindable var draft = draft
            let projects = projects
            let vocabulary = CaptureVocabulary(projects: projects.map(\.title), contexts: contexts.filter { !$0.isHidden }.map(\.name))
            let known = Known(parsed: Capture.entry(draft.text, today: model.today, vocabulary: vocabulary).draft, projects: projects)
            VStack(spacing: 0) {
                MarkdownWebEditor(
                    text: $draft.text, focusesOnOpen: true, placeholder: "What's on your mind?", textScale: 1.3, firstLineIsTitle: true,
                    submit: add, cancel: cancel
                )
                .background {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 96, weight: .light))
                        .foregroundStyle(.quaternary)
                        .opacity(0.7)
                        .accessibilityHidden(true)
                }
                .frame(height: 170)
                .padding(Spacing.large)
                Divider()
                HStack(alignment: .top, spacing: Spacing.wide) {
                    column(.belongs, [.area, .project], known: known)
                    column(.when, [.scheduled, .due, .repeats], known: known)
                    column(.doing, [.contexts, .timeEstimate, .energy], known: known)
                }
                .padding(Spacing.large)
                Divider()
                HStack {
                    Text(inbox.count == 1 ? "1 item in the Inbox" : "\(inbox.count) items in the Inbox")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showsKeyHints {
                        keyLegend
                    }
                }
                .font(.callout)
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.medium)
            }
            .frame(width: Self.width)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .onExitCommand(perform: cancel)
        }

        /// The panel's own keys: ⌘O opens the app's window, ⌘Return adds, Escape closes.
        private var keyLegend: some View {
            HStack(spacing: Spacing.medium) {
                legendItem(["⌘", "O"], "Open Cecily Tasks")
                legendItem(["⌘", "↩"], "Add")
                legendItem(["esc"], "Close")
            }
            .foregroundStyle(.secondary)
        }

        private func legendItem(_ caps: [String], _ name: String) -> some View {
            HStack(spacing: Spacing.tight) {
                KeyCaps(caps: caps, isSmall: true, isDimmed: true)
                Text(name)
            }
        }

        /// What the first line's tokens name, and the tasks a new item can go under.
        private struct Known {
            let parsed: CaptureDraft
            let projects: [Item]
        }

        private func column(_ group: ItemField.Group, _ fields: [ItemField], known: Known) -> some View {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(group.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(fields, id: \.self) { field in
                    let chord = KeyCommand.opening(.field(field))?.chord
                    HStack(spacing: Spacing.small) {
                        Label {
                            HStack(spacing: Spacing.small) {
                                Text(field.placeholder)
                                if showsKeyHints, let chord {
                                    Text(KeyCommand.label(chord))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                            }
                        } icon: {
                            Image(systemName: field.symbol)
                        }
                        .labelStyle(DetailLabelStyle())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Spacer(minLength: Spacing.tight)
                        Button(value(field, known: known)) { editing = field }
                            .keyboardShortcut(chord)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .lineLimit(1)
                            .popover(isPresented: isEditing(field)) { editor(field, known: known) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func isEditing(_ field: ItemField) -> Binding<Bool> {
            Binding(get: { editing == field }, set: { if !$0 { editing = nil } })
        }

        /// What the detail is: the one chosen, or else what the first line's tokens name, or the
        /// lists' area.
        private func value(_ field: ItemField, known: Known) -> String {
            let details = draft.details
            let parsed = known.parsed
            switch field {
            case .area:
                return chosenArea.flatMap { id in areas.first { $0.id == id }?.displayName } ?? "None"
            case .project:
                switch details.project {
                case .unchosen: return parsed.project ?? "None"
                case .chosen(let id): return id.flatMap { id in known.projects.first { $0.id == id }?.displayTitle } ?? "None"
                }
            case .scheduled:
                return details.scheduled.or(parsed.scheduledDate).map(CaptureDraft.format) ?? "None"
            case .due:
                return details.due.or(parsed.dueDate).map(CaptureDraft.format) ?? "None"
            case .repeats:
                return repeats(known).flatMap { CaptureParser.repeatRule($0, today: model.today)?.label } ?? "None"
            case .contexts:
                let names = chosenContexts(known).compactMap { id in contexts.first { $0.id == id }?.name }
                return names.isEmpty ? "None" : names.joined(separator: ", ")
            case .timeEstimate:
                return details.timeEstimate?.longName ?? "None"
            case .energy:
                return details.energy?.name ?? "None"
            default:
                return "None"
            }
        }

        @ViewBuilder private func editor(_ field: ItemField, known: Known) -> some View {
            let parsed = known.parsed
            switch field {
            case .scheduled:
                DayEditor(day: draft.details.scheduled.or(parsed.scheduledDate)) { draft.details.scheduled = .chosen($0) }
            case .due:
                DayEditor(day: draft.details.due.or(parsed.dueDate)) { draft.details.due = .chosen($0) }
            case .area:
                let area = chosenArea
                ChoiceList(
                    choices: [choice("none", "None", area == nil) { $0.area = .chosen(nil) }]
                        + areas.map { each in choice(each.id.uuidString, each.displayName, area == each.id) { $0.area = .chosen(each.id) } })
            case .project:
                let project = project(known)
                ChoiceList(
                    choices: [choice("none", "None", project == nil) { $0.project = .chosen(nil) }]
                        + known.projects.map { each in
                            choice(each.id.uuidString, each.displayTitle, project == each.id) { $0.project = .chosen(each.id) }
                        })
            case .repeats:
                let repeats = repeats(known)
                ChoiceList(
                    choices: [choice("none", "None", repeats == nil) { $0.repeats = .chosen(nil) }]
                        + Self.repeats.compactMap { phrase in
                            CaptureParser.repeatRule(phrase, today: model.today).map { rule in
                                choice(phrase, rule.label, repeats == phrase) { $0.repeats = .chosen(phrase) }
                            }
                        })
            case .contexts:
                let chosen = chosenContexts(known)
                ChoiceList(
                    choices: contexts.filter { !$0.isHidden }.map { context in
                        let has = chosen.contains(context.id)
                        return choice(context.id.uuidString, context.name, has) { details in
                            details.contexts = .chosen(has ? chosen.filter { $0 != context.id } : chosen + [context.id])
                        }
                    }, keepsOpen: true)
            case .timeEstimate:
                ChoiceList(
                    choices: [choice("none", "None", draft.details.timeEstimate == nil) { $0.timeEstimate = nil }]
                        + TimeEstimate.allCases.map { time in
                            choice(time.rawValue, time.longName, draft.details.timeEstimate == time) { $0.timeEstimate = time }
                        })
            case .energy:
                ChoiceList(
                    choices: [choice("none", "None", draft.details.energy == nil) { $0.energy = nil }]
                        + Energy.allCases.map { energy in choice(energy.rawValue, energy.name, draft.details.energy == energy) { $0.energy = energy }
                        })
            default:
                EmptyView()
            }
        }

        private func choice(_ id: String, _ name: String, _ isOn: Bool, _ set: @escaping (inout CaptureDetails) -> Void) -> ChoiceList.Choice {
            ChoiceList.Choice(id: id, name: name, isOn: isOn) { set(&draft.details) }
        }

        /// The area chosen, or else the lists' area.
        private var chosenArea: UUID? {
            draft.details.area.or(model.area)
        }

        /// The task chosen to go under, or else the one the first line's tokens name.
        private func project(_ known: Known) -> UUID? {
            switch draft.details.project {
            case .unchosen: known.parsed.project.flatMap { name in known.projects.first { $0.title == name }?.id }
            case .chosen(let id): id
            }
        }

        /// The repeat chosen, or else the one the first line's tokens name.
        private func repeats(_ known: Known) -> String? {
            draft.details.repeats.or(known.parsed.repeatText)
        }

        /// The contexts chosen, or else those the first line's tokens name.
        private func chosenContexts(_ known: Known) -> [UUID] {
            draft.details.contexts.or(known.parsed.contexts.compactMap { name in contexts.first { $0.name == name }?.id }) ?? []
        }

        /// The tasks a new item can go under: open tasks with subtasks in Actions, on Someday or
        /// in Reference, by title.
        private var projects: [Item] {
            openItems.filter { $0.isOpenProject && [.action, .someday, .reference].contains($0.bucket) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        private func add() {
            draft.add(to: model)
        }

        private func cancel() {
            draft.clear()
            close()
        }
    }
#endif
