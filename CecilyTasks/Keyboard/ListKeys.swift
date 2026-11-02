#if os(macOS)
    import AppKit
    import SwiftUI
    import WebKit

    /// Sends keys typed in a window to the list showing there, while the list has the keyboard or
    /// nothing does: the keys in `KeyCommand` pressed on their own, its
    /// chords that work only in lists, ← and → to Agenda's timeline, and ↑ and ↓ when no list has
    /// the keyboard, which give it to the list showing and move its selection the list's own way. Escape, unless a field has the
    /// cursor, goes to the list too, to close the open item. Each list adds itself as it appears
    /// and goes as it disappears; the last one added in a window gets the keys. Sheets, popovers,
    /// panels and other windows keep their own.
    @MainActor
    final class ListKeys {
        static let shared = ListKeys()

        /// A list that takes keys: a view in it, its window, what it does with a command (true
        /// when it did something), and whether it takes ↑ and ↓ now.
        final class Target {
            weak var anchor: NSView?
            weak var window: NSWindow?
            var perform: (KeyCommand) -> Bool = { _ in false }
            var takesArrows: () -> Bool = { true }
            /// Moves Agenda's timeline a stop before (-1) or after (1); false when it isn't showing.
            var stepsStops: (Int) -> Bool = { _ in false }

            /// The table that shows the list's rows: the nearest one around its anchor.
            var table: NSTableView? {
                var view = anchor?.superview
                while let current = view {
                    if let table = current.firstDescendant(of: NSTableView.self) { return table }
                    view = current.superview
                }
                return nil
            }

            /// Whether the event being handled is a click on the list's rows.
            var isBeingClicked: Bool {
                guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp, let table,
                    event.window === table.window
                else { return false }
                return table.visibleRect.contains(table.convert(event.locationInWindow, from: nil))
            }
        }

        private var targets: [Target] = []
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { ListKeys.shared.handle(event) } ? nil : event
            }
        }

        func add(_ target: Target) {
            targets.removeAll { $0 === target }
            targets.append(target)
        }

        func remove(_ target: Target) {
            targets.removeAll { $0 === target }
        }

        /// Sends the key to the list when the list has the keyboard, or nothing does: a bare key or
        /// a chord that works only in lists to its command, which beeps when it can't do anything,
        /// and ↑ or ↓ to its table when the table doesn't have the keyboard already. Anything else
        /// that has the keyboard, such as the sidebar, a field or a button, keeps it.
        private func handle(_ event: NSEvent) -> Bool {
            if event.keyCode == Self.escape, EventModifiers(event.modifierFlags).isEmpty, let window = event.window,
                window.attachedSheet == nil, !(window.firstResponder is NSText), let target = targets.last(where: { $0.window === window })
            {
                return target.perform(KeyCommand.close)
            }
            guard let window = event.window, window.attachedSheet == nil, !Self.isTyping(in: window),
                let target = targets.last(where: { $0.window === window })
            else { return false }
            let table = target.table
            let listHasKeyboard = table != nil && window.firstResponder === table
            guard listHasKeyboard || Self.canTakeKeyboard(in: window) else { return false }
            let modifiers = EventModifiers(event.modifierFlags)
            if let arrow = Self.arrows[event.keyCode] {
                if let command = KeyCommand.listOnly(arrow, modifiers: modifiers) {
                    guard target.takesArrows() else { return false }
                    if !target.perform(command) { NSSound.beep() }
                    return true
                }
                if arrow == .leftArrow || arrow == .rightArrow {
                    guard modifiers.isEmpty, target.takesArrows() else { return false }
                    return target.stepsStops(arrow == .leftArrow ? -1 : 1)
                }
                guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
                guard !listHasKeyboard, target.takesArrows(), let table, window.makeFirstResponder(table) else { return false }
                table.keyDown(with: event)
                return true
            }
            guard let command = KeyCommand.bare(event.characters ?? "", modifiers: modifiers) else { return false }
            return target.perform(command)
        }

        /// The arrow keys, by their key codes.
        private static let arrows: [UInt16: KeyEquivalent] = [126: .upArrow, 125: .downArrow, 123: .leftArrow, 124: .rightArrow]
        private static let escape: UInt16 = 53

        /// Whether a list can take the window's keyboard without taking it from anything else:
        /// nothing has it, a list has it, or what had it has gone from the window.
        static func canTakeKeyboard(in window: NSWindow?) -> Bool {
            guard let window, let responder = window.firstResponder, responder !== window else { return true }
            guard let view = responder as? NSView else { return false }
            return view.window == nil || shared.targets.contains { $0.table === view }
        }

        /// Whether a field or the notes have the window's keyboard, so keys are for typing.
        static func isTyping(in window: NSWindow?) -> Bool {
            guard let responder = window?.firstResponder else { return false }
            if responder is NSText { return true }
            var view = responder as? NSView
            while let current = view {
                if current is WKWebView { return true }
                view = current.superview
            }
            return false
        }
    }

    extension NSView {
        /// The first view of `type` among this view's descendants, nearest first.
        fileprivate func firstDescendant<T: NSView>(of type: T.Type) -> T? {
            var queue = subviews
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let found = view as? T { return found }
                queue += view.subviews
            }
            return nil
        }
    }

    extension EventModifiers {
        /// The modifier keys held in an AppKit event.
        init(_ flags: NSEvent.ModifierFlags) {
            self = []
            if flags.contains(.command) { insert(.command) }
            if flags.contains(.option) { insert(.option) }
            if flags.contains(.control) { insert(.control) }
            if flags.contains(.shift) { insert(.shift) }
        }
    }

    /// Tells `found` about the view it's put behind, whenever it moves to a window.
    struct WindowReader: NSViewRepresentable {
        let found: (NSView) -> Void

        func makeNSView(context: Context) -> ReaderView {
            let view = ReaderView()
            view.found = found
            return view
        }

        func updateNSView(_ view: ReaderView, context: Context) {
            view.found = found
        }

        final class ReaderView: NSView {
            var found: ((NSView) -> Void)?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                found?(self)
            }
        }
    }
#endif
