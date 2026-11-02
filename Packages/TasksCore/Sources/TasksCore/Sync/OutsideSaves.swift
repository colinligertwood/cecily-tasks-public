import Foundation
import SwiftData

/// Notices what the app's extensions saved to the shared store, from its history. Their saves
/// carry `author`.
public struct OutsideSaves {
    public static let author = "tasks-extension"

    private var token: DefaultHistoryToken?

    /// Starts from the store as it is now.
    public init(_ container: ModelContainer) {
        token = Self.latest(in: ModelContext(container))
    }

    /// Whether an extension has saved anything since the last call, or since `init`.
    public mutating func check(_ container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token { descriptor.predicate = #Predicate { $0.token > token } }
        guard let history = try? context.fetchHistory(descriptor), let last = history.last else { return false }
        token = last.token
        return history.contains { $0.author == Self.author }
    }

    private static func latest(in context: ModelContext) -> DefaultHistoryToken? {
        (try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()))?.last?.token
    }
}
