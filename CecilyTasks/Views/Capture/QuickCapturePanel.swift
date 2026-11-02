#if os(macOS)
    import AppKit
    import Carbon.HIToolbox
    import SwiftData
    import SwiftUI

    /// The Mac's floating quick entry panel (`QuickEntryView`), opened from anywhere by a keyboard
    /// shortcut or the menu-bar icon. The shortcut is registered with the
    /// system, so it works whichever app is in front, and needs no permission.
    @MainActor
    final class QuickCapturePanel: NSObject {
        static let shared = QuickCapturePanel()
        static let shortcutKey = "quick-capture-shortcut"

        /// The shortcuts to choose from in Settings.
        enum Shortcut: String, CaseIterable, Identifiable {
            case controlOptionSpace
            case optionSpace
            case controlOptionI
            case off

            var id: Self { self }

            var label: String {
                switch self {
                case .controlOptionSpace: "⌃⌥Space"
                case .optionSpace: "⌥Space"
                case .controlOptionI: "⌃⌥I"
                case .off: "None"
                }
            }

            fileprivate var key: (code: Int, modifiers: Int)? {
                switch self {
                case .controlOptionSpace: (kVK_Space, controlKey | optionKey)
                case .optionSpace: (kVK_Space, optionKey)
                case .controlOptionI: (kVK_ANSI_I, controlKey | optionKey)
                case .off: nil
                }
            }
        }

        weak var model: AppModel?
        private var panel: NSPanel?
        private var hotKey: EventHotKeyRef?
        private var handler: EventHandlerRef?

        static var current: Shortcut {
            UserDefaults.standard.string(forKey: shortcutKey).flatMap(Shortcut.init) ?? .controlOptionSpace
        }

        /// Registers the chosen shortcut, replacing any registered before.
        func registerShortcut() {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            if handler == nil {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(
                    GetApplicationEventTarget(),
                    { _, _, _ in
                        Task { @MainActor in QuickCapturePanel.shared.toggle() }
                        return noErr
                    }, 1, &spec, nil, &handler)
            }
            guard let key = Self.current.key else { return }
            let id = EventHotKeyID(signature: OSType(0x4354_534B), id: 1)
            RegisterEventHotKey(UInt32(key.code), UInt32(key.modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
        }

        /// What's typed in it, kept while it's closed.
        let draft = QuickEntryDraft()
        private var statusItem: NSStatusItem?
        private var resigning: Any?
        /// The model the panel's view was made for.
        private var shownModel: ObjectIdentifier?

        /// Puts the menu-bar icon in place, which opens the panel.
        func addStatusItem() {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Cecily Tasks Quick Entry")
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            statusItem = item
        }

        @objc private func statusItemClicked() {
            toggle()
        }

        func toggle() {
            if let panel, panel.isVisible, !isHiding {
                hide()
            } else {
                show()
            }
        }

        /// Whether the panel is fading out.
        private var isHiding = false

        /// Fades the panel out, then closes it.
        func hide() {
            guard let panel, panel.isVisible, !isHiding else { return }
            isHiding = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    guard self.isHiding else { return }
                    self.isHiding = false
                    panel.close()
                    panel.alphaValue = 1
                }
            }
        }

        /// Shows the panel above the middle of the screen with the pointer, as Spotlight's is,
        /// without bringing the app's window forward. Its view, and the editor in it, are made once
        /// for each store.
        func show() {
            guard let model else { return }
            let panel = self.panel ?? makePanel()
            isHiding = false
            if shownModel != ObjectIdentifier(model) {
                let content = QuickEntryView(draft: draft) { [weak self] in self?.hide() }
                    .modifier(Appearing(draft: draft))
                    .environment(model)
                    .modelContainer(model.container)
                panel.contentView = NSHostingView(rootView: content)
                shownModel = ObjectIdentifier(model)
            }
            let size = panel.contentView?.fittingSize ?? NSSize(width: QuickEntryView.width, height: 420)
            panel.setContentSize(size)
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2))
            }
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            Task { @MainActor in self.draft.shows += 1 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            self.panel = panel
        }

        private func makePanel() -> NSPanel {
            let panel = EntryPanel(
                contentRect: NSRect(x: 0, y: 0, width: QuickEntryView.width, height: 420),
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Giving up the keyboard to anything but its own popovers closes it, keeping what's typed.
            resigning = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard let panel = self?.panel else { return }
                    if let key = NSApp.keyWindow, key === panel || key.parent === panel { return }
                    self?.hide()
                }
            }
            return panel
        }
    }

    /// Grows the panel's content into place each time it's shown, from a little smaller.
    private struct Appearing: ViewModifier {
        let draft: QuickEntryDraft

        func body(content: Content) -> some View {
            content.keyframeAnimator(initialValue: 1.0, trigger: draft.shows) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0.95)
                    SpringKeyframe(1.0, duration: 0.25, spring: .init(duration: 0.25, bounce: 0.2))
                }
            }
        }
    }

    /// A panel without a title bar that can still take the keyboard. Wherever the keyboard is in
    /// it, ⌘Return adds what's typed and ⌘O closes it and opens the app's window.
    private final class EntryPanel: NSPanel {
        override var canBecomeKey: Bool { true }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if modifiers == .command, event.charactersIgnoringModifiers == "\r", let model = QuickCapturePanel.shared.model {
                QuickCapturePanel.shared.draft.add(to: model)
                return true
            }
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "o" {
                QuickCapturePanel.shared.hide()
                MainWindow.open()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
#endif
