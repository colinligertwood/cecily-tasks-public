import Foundation

/// What several items have for one detail: all the same value, or not.
public enum Shared<Value: Equatable>: Equatable {
    case same(Value)
    case mixed

    /// The items' value, `same` when they all have it. Nil for no items.
    public init?<S: Sequence>(_ items: S, _ value: (Item) -> Value) where S.Element == Item {
        var first: Value?
        for item in items {
            let this = value(item)
            if let first, first != this {
                self = .mixed
                return
            }
            first = this
        }
        guard let first else { return nil }
        self = .same(first)
    }
}

extension Item {
    /// Adds the context or takes it away, whichever `has` says.
    public func setContext(_ context: Context, _ has: Bool, at now: Date = .now) {
        let present = contexts?.contains { $0.id == context.id } ?? false
        guard present != has else { return }
        toggle(context, at: now)
    }
}
