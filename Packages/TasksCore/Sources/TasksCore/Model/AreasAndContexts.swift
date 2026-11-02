import Foundation
import SwiftData

// Changes to areas and contexts, from Settings. Each setter changes `modifiedAt` only when the
// value changes.

extension Area {
    public func setName(_ name: String, at now: Date = .now) {
        guard name != self.name else { return }
        self.name = name
        modifiedAt = now
    }

    /// Numbers `areas` in their order, setting `modifiedAt` on those whose place changes.
    public static func putInOrder(_ areas: [Area], at now: Date = .now) {
        for (index, area) in areas.enumerated() where area.sortOrder != Double(index) {
            area.sortOrder = Double(index)
            area.modifiedAt = now
        }
    }

    /// Deletes the area. Its projects and items stay, with no area.
    public func delete(at now: Date = .now) {
        for item in items ?? [] {
            item.area = nil
            item.modifiedAt = now
        }
        modelContext?.delete(self)
    }
}

extension Context {
    public func setName(_ name: String, at now: Date = .now) {
        guard name != self.name else { return }
        self.name = name
        modifiedAt = now
    }

    /// Hides the context from the menus and Actions' groups, or shows it again.
    public func setHidden(_ isHidden: Bool, at now: Date = .now) {
        guard isHidden != self.isHidden else { return }
        self.isHidden = isHidden
        modifiedAt = now
    }

    /// Numbers `contexts` in their order, setting `modifiedAt` on those whose place changes.
    public static func putInOrder(_ contexts: [Context], at now: Date = .now) {
        for (index, context) in contexts.enumerated() where context.sortOrder != Double(index) {
            context.sortOrder = Double(index)
            context.modifiedAt = now
        }
    }

    /// Deletes a context that isn't built in, taking it off its items. Built-in contexts are
    /// hidden instead, and stay as they are.
    public func delete(at now: Date = .now) {
        guard !isBuiltIn else { return }
        for item in items ?? [] {
            item.contexts = (item.contexts ?? []).filter { $0.id != id }
            item.modifiedAt = now
        }
        modelContext?.delete(self)
    }
}
