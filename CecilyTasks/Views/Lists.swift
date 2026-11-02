import SwiftData
import SwiftUI
import TasksCore

extension Item {
    /// Whether the item is in the area, directly or through its project. Every item is in a nil area.
    func isIn(area: UUID?) -> Bool {
        guard let area else { return true }
        return (self.area ?? project?.area)?.id == area
    }
}

/// Narrows the lists to one area, from the toolbar.
struct AreaFilter: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Area.sortOrder) private var areas: [Area]

    var body: some View {
        @Bindable var model = model
        let chosen = areas.first { $0.id == model.area }
        Menu {
            Picker("Area", selection: $model.area) {
                Text("All Areas").tag(UUID?.none)
                Divider()
                ForEach(areas) { area in
                    Text(area.displayName).tag(Optional(area.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            SettingsPaneButton(title: "Edit Areas…", pane: .areas)
        } label: {
            Label(chosen.map { $0.displayName } ?? "All Areas", systemImage: ItemField.area.symbol)
                .labelStyle(.titleAndIcon)
        }
        .help(chosen.map { "Showing \($0.name) only" } ?? "Show one area only")
        .onChange(of: areas.map(\.id)) { _, ids in
            if let area = model.area, !ids.contains(area) { model.area = nil }
        }
    }
}
