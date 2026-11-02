import SwiftData
import SwiftUI
import TasksCore

/// A part of Settings: the general settings, notifications, areas or contexts.
enum SettingsPane: String, Identifiable {
    case general
    case notifications
    case calendars
    case areas
    case contexts

    /// The pane the Mac's Settings window shows.
    static let key = "settings-pane"

    var id: Self { self }
}

/// A button that opens Settings at `pane`: the Mac's Settings window, or a sheet on iPhone.
struct SettingsPaneButton: View {
    let title: String
    let pane: SettingsPane
    @Environment(AppModel.self) private var model
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        Button(title) {
            #if os(macOS)
                UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.key)
                openSettings()
            #else
                model.settingsSheet = pane
            #endif
        }
    }
}

/// The areas, in their order: each renamed in place, put in order by dragging, and deleted, which
/// keeps its projects and items with no area.
struct AreasSettings: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Area.sortOrder) private var areas: [Area]
    @State private var deleting: Area?

    var body: some View {
        List {
            Section {
                ForEach(areas) { area in
                    DoneTypingField("Name", text: area.name) { name in model.edit(area) { $0.setName(name) } }
                        .contextMenu {
                            Button("Delete…", role: .destructive) { deleting = area }
                        }
                }
                .onMove { from, to in
                    var ordered = areas
                    ordered.move(fromOffsets: from, toOffset: to)
                    Area.putInOrder(ordered)
                    model.save()
                }
                .onDelete { offsets in deleting = offsets.first.map { areas[$0] } }
            } footer: {
                Text("Areas are the parts of your life and work that never end, such as Home, Health, or a job. Drag to put them in order.")
            }
            Section {
                Button("Add Area", systemImage: "plus") {
                    _ = NewRecord.area(named: "New Area", in: model.context)
                    model.save()
                }
            }
        }
        .navigationTitle("Areas")
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Area", role: .destructive) {
                if let area = deleting {
                    if model.area == area.id { model.area = nil }
                    area.delete()
                    model.save()
                }
                deleting = nil
            }
        } message: {
            Text("Its projects and items stay, with no area.")
        }
    }
}

/// The contexts, in their order: each renamed in place and put in order by dragging. Built-in ones
/// can be hidden; the others deleted, which takes them off their items.
struct ContextsSettings: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Context.sortOrder) private var contexts: [Context]
    @State private var deleting: Context?

    var body: some View {
        List {
            Section {
                ForEach(contexts) { context in
                    HStack {
                        Image(systemName: context.symbol.isEmpty ? ItemField.contexts.symbol : context.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: Spacing.wide)
                        DoneTypingField("Name", text: context.name) { name in model.edit(context) { $0.setName(name) } }
                        if context.isBuiltIn {
                            Toggle(
                                "Shown",
                                isOn: Binding(get: { !context.isHidden }, set: { shown in model.edit(context) { $0.setHidden(!shown) } })
                            )
                            .labelsHidden()
                        }
                    }
                    .contextMenu {
                        if !context.isBuiltIn {
                            Button("Delete…", role: .destructive) { deleting = context }
                        }
                    }
                    .deleteDisabled(context.isBuiltIn)
                }
                .onMove { from, to in
                    var ordered = contexts
                    ordered.move(fromOffsets: from, toOffset: to)
                    Context.putInOrder(ordered)
                    model.save()
                }
                .onDelete { offsets in deleting = offsets.first.map { contexts[$0] } }
            } footer: {
                Text("Where or with what an action can be done. Built-in contexts can be hidden but not deleted. Drag to put them in order.")
            }
            Section {
                Button("Add Context", systemImage: "plus") {
                    _ = NewRecord.context(named: "New Context", in: model.context)
                    model.save()
                }
            }
        }
        .navigationTitle("Contexts")
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Context", role: .destructive) {
                deleting?.delete()
                model.save()
                deleting = nil
            }
        } message: {
            Text("It's taken off the actions that have it.")
        }
    }
}
