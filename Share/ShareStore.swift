import Foundation
import SwiftData
import TasksCore

/// Adds a shared item to the person's store in the App Group container, which the app syncs.
enum ShareStore {
    enum Problem: Error {
        /// The app hasn't yet moved its store to the App Group container.
        case noStore
    }

    static func add(_ shared: SharedItem) throws {
        guard let folder = StoreFolder.shared else { throw Problem.noStore }
        let url = folder.appending(path: StoreFolder.storeName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Problem.noStore }
        let context = ModelContext(try TasksSchema.container(at: url))
        context.author = OutsideSaves.author
        shared.add(to: context)
        try context.save()
    }
}
