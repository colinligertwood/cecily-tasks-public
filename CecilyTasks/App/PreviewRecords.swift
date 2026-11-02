import Foundation
import SwiftData
import SwiftUI
import TasksCore

/// Previews with a few made-up records in a store in memory that never syncs:
/// `#Preview(traits: .previewRecords)`.
struct PreviewRecords: PreviewModifier {
    static func makeSharedContext() async throws -> Store {
        let store = try Store.open(in: nil, canSync: false).get()
        try fill(store.model.context)
        return store
    }

    func body(content: Content, context: Store) -> some View {
        content
            .environment(context.model)
            .environment(context.model.cloudSync)
            .modelContainer(context.model.container)
    }

    /// One or two items in each list, an area, and a task with subtasks.
    static func fill(_ context: ModelContext) throws {
        let today = LocalDate(.now, in: .current)
        let contexts = try context.fetch(FetchDescriptor<TasksCore.Context>())
        let calls = contexts.first { $0.name == "Calls" }
        let errands = contexts.first { $0.name == "Errands" }
        let home = Area(name: "Home")
        context.insert(home)

        func item(_ title: String, _ bucket: Bucket, configure: (Item) -> Void = { _ in }) {
            let made = Item(title: title, bucket: bucket)
            context.insert(made)
            configure(made)
        }
        item("Look into a new phone contract", .inbox)
        item("Book a table for Friday", .inbox) { $0.source = .share }
        item("Ring the dentist", .action) {
            $0.contexts = calls.map { [$0] }
            $0.dueDate = today.storedDate
        }
        item("Pick up the dry cleaning", .action) {
            $0.contexts = errands.map { [$0] }
            $0.area = home
            $0.timeEstimate = .fifteenMinutes
        }
        item("Water the plants", .action) {
            $0.area = home
            $0.scheduledDate = today.storedDate
        }
        item("Quote for the new boiler", .waiting) {
            $0.waitingOn = "the heating engineer"
            $0.followUpDate = today.adding(days: 3).storedDate
        }
        item("Learn to sail", .someday)
        item("Wi-Fi and router", .reference) {
            $0.kind = .note
            $0.area = home
            $0.body = "**Network:** Ashgrove"
        }
        item("Old broadband offer", .trash) {
            $0.trashedFrom = .someday
            $0.trashedAt = .now
        }

        let shed = Item(title: "Garden shed cleared out", bucket: .action)
        shed.area = home
        context.insert(shed)
        for (index, title) in ["Sort the tools", "Take the rubbish to the tip"].enumerated() {
            let step = Item(title: title, bucket: .action)
            step.sortOrder = Double(index)
            step.parent = shed
            context.insert(step)
        }
        try context.save()
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    static var previewRecords: Self { .modifier(PreviewRecords()) }
}
