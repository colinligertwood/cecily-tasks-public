import OSLog
import SwiftUI
import TasksCore
import UniformTypeIdentifiers
import WebKit

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The Markdown editor: CodeMirror 6 with ProseMark in a web view (`Editor/`, built into
/// `editor.js`). Markdown renders as it's typed and its symbols show where the cursor is. The text stays plain
/// Markdown, exactly as typed. It loads nothing from the network, fills the space it's given and
/// scrolls inside itself, and opens web links in the browser. With `links`, typing `[[` offers
/// items and areas to link to, links to them show their current titles and open them, and a web
/// address pasted on its own becomes a link with the page's title. With `takeFiles`, files pasted
/// or dropped into it go there, not into the text. `textScale` sizes its text from the system's
/// body size, and with `firstLineIsTitle` its first line shows larger and bold. On the Mac,
/// `submit` takes ⌘Return and `cancel` takes Escape.
struct MarkdownWebEditor: View {
    @Binding var text: String
    /// Whether the cursor goes in it as soon as it's ready.
    var focusesOnOpen = false
    /// What shows while it's empty.
    var placeholder: String?
    /// What finds, names and opens links to items and areas.
    var links: (any NoteLinking)?
    /// The item whose notes these are, which isn't offered as a link.
    var noteID: UUID?
    /// What takes files pasted or dropped into it.
    var takeFiles: (([PastedFile]) -> Void)?
    var textScale: CGFloat = 1
    var firstLineIsTitle = false
    var submit: (() -> Void)?
    var cancel: (() -> Void)?

    var body: some View {
        MarkdownWebView(
            text: $text, focusesOnOpen: focusesOnOpen, placeholder: placeholder, links: links, noteID: noteID, takeFiles: takeFiles,
            look: MarkdownWebCoordinator.Look(textScale: textScale, firstLineIsTitle: firstLineIsTitle), submit: submit, cancel: cancel)
    }
}

/// What the notes editor asks about links to items and areas.
@MainActor
protocol NoteLinking: AnyObject {
    /// The items and areas to offer for what's been typed after `[[`.
    func linkTargets(matching query: String, excluding: UUID?) -> [NoteLink.Target]
    /// The links' targets as they are now, by link URL.
    func linkTitles(_ urls: [String]) -> [String: (title: String?, isGone: Bool)]
    func open(_ link: NoteLink)
}

/// A file pasted or dropped into the editor: its name, and its contents, or nil when it's bigger
/// than an attachment can be.
struct PastedFile {
    let name: String
    let data: Data?
}

/// How long the editor took to be ready, the last time one opened.
@MainActor
enum MarkdownWebEditorTiming {
    static var lastOpen: Duration?
}

final class MarkdownWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var text: Binding<String>
    weak var webView: WKWebView?
    /// The text the editor last had, so a change from it isn't sent back.
    var shown = ""
    var focusesOnOpen = false
    var placeholder: String?
    weak var links: (any NoteLinking)?
    var noteID: UUID?
    var takeFiles: (([PastedFile]) -> Void)?
    var look = Look()
    var submit: (() -> Void)?
    var cancel: (() -> Void)?
    private var isReady = false

    /// How the text is sized: a multiple of the system's body size, and whether the first line
    /// is larger and bold.
    struct Look: Equatable {
        var textScale: CGFloat = 1
        var firstLineIsTitle = false
    }
    private let opened = ContinuousClock.now
    private let log = Logger(subsystem: "com.ligertwood.cecily.tasks", category: "editor")

    init(text: Binding<String>) {
        self.text = text
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            let elapsed = ContinuousClock.now - opened
            MarkdownWebEditorTiming.lastOpen = elapsed
            log.notice("Editor ready in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            sendTheme()
            send(text.wrappedValue)
            if let placeholder {
                webView?.callAsyncJavaScript("cecily.setPlaceholder(text)", arguments: ["text": placeholder], in: nil, in: .page) { _ in }
            }
            if takeFiles != nil { call("cecily.setTakesFiles(value)", ["value": true]) }
            if focusesOnOpen { focus() }
        case "change":
            guard let value = body["text"] as? String else { return }
            shown = value
            if text.wrappedValue != value { text.wrappedValue = value }
        case "openLink":
            guard let string = body["url"] as? String else { return }
            if let link = NoteLink(string) {
                links?.open(link)
            } else if let url = URL(string: string), ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                Self.open(url)
            }
        case "findLinks":
            guard let id = body["id"] as? Int, let query = body["query"] as? String else { return }
            let targets = (links?.linkTargets(matching: query, excluding: noteID) ?? []).map { target in
                ["title": target.title, "place": target.place, "markdown": NoteLink.markdown(title: target.title, url: target.link.url)]
            }
            call("cecily.linksFound(id, targets)", ["id": id, "targets": targets])
        case "resolveLinks":
            guard let urls = body["urls"] as? [String], let links else { return }
            let titles = links.linkTitles(urls).mapValues { target -> [String: Any] in
                ["title": target.title ?? NSNull(), "isGone": target.isGone]
            }
            call("cecily.setLinkTitles(titles)", ["titles": titles])
        case "pastedURL":
            guard let id = body["id"] as? Int, let string = body["url"] as? String, let url = URL(string: string) else { return }
            Task {
                let link = await Self.pageTitle(url).map { NoteLink.markdown(title: $0, url: string) }
                call("cecily.titleLink(id, link)", ["id": id, "link": link ?? NSNull()])
            }
        case "files":
            guard let files = body["files"] as? [[String: Any]] else { return }
            takeFiles?(files.map(Self.pastedFile))
        default:
            break
        }
    }

    /// A file as the page sends it, named with its type's extension when its name has none.
    private static func pastedFile(_ file: [String: Any]) -> PastedFile {
        var name = (file["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Pasted file"
        if (name as NSString).pathExtension.isEmpty, let type = (file["type"] as? String).flatMap({ UTType(mimeType: $0) }),
            let ext = type.preferredFilenameExtension
        {
            name += ".\(ext)"
        }
        return PastedFile(name: name, data: (file["data"] as? String).flatMap { Data(base64Encoded: $0) })
    }

    /// Shows `value` in the editor, unless it's what's there already.
    func send(_ value: String) {
        guard isReady, value != shown, let webView else { return }
        shown = value
        webView.callAsyncJavaScript("cecily.setText(text)", arguments: ["text": value], in: nil, in: .page) { _ in }
    }

    private func call(_ script: String, _ arguments: [String: Any]) {
        guard isReady, let webView else { return }
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { _ in }
    }

    /// The title of the web page at `url`, or nil if it can't be had within 3 seconds.
    static func pageTitle(_ url: URL) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await WebLinkTitle.fetchTitle(url) { try await URLSession.shared.data(from: $0).0 } }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Puts the cursor in the editor.
    func focus() {
        guard isReady, let webView else { return }
        #if os(macOS)
            webView.window?.makeFirstResponder(webView)
        #endif
        webView.callAsyncJavaScript("cecily.focus()", arguments: [:], in: nil, in: .page) { _ in }
    }

    func sendTheme() {
        guard isReady, let webView else { return }
        var theme = Self.theme(for: webView)
        if let size = theme["fontSize"] as? CGFloat { theme["fontSize"] = size * look.textScale }
        theme["titleLine"] = look.firstLineIsTitle
        webView.callAsyncJavaScript("cecily.setTheme(theme)", arguments: ["theme": theme], in: nil, in: .page) { _ in }
    }

    /// The system's colours and text size, as the page wants them: the size of a row's title
    /// (`Font.rowTitle`), to match the card the notes are in.
    static func theme(for view: WKWebView) -> [String: Any] {
        #if os(macOS)
            var theme: [String: Any] = [:]
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                theme = [
                    "label": css(.labelColor), "secondary": css(.secondaryLabelColor), "dimmed": css(.tertiaryLabelColor),
                    "accent": css(.controlAccentColor), "selection": css(.selectedTextBackgroundColor),
                    "separator": css(.separatorColor), "fill": css(.tertiarySystemFill),
                    "fontSize": NSFont.preferredFont(forTextStyle: .body).pointSize,
                ]
            }
            return theme
        #else
            let traits = view.traitCollection
            func css(_ color: UIColor) -> String { Self.css(color.resolvedColor(with: traits)) }
            return [
                "label": css(.label), "secondary": css(.secondaryLabel), "dimmed": css(.tertiaryLabel), "accent": css(view.tintColor),
                "selection": css(view.tintColor.withAlphaComponent(0.25)), "separator": css(.separator), "fill": css(.tertiarySystemFill),
                "fontSize": UIFont.preferredFont(forTextStyle: .body).pointSize,
            ]
        #endif
    }

    #if os(macOS)
        static func css(_ color: NSColor) -> String {
            guard let rgb = color.usingColorSpace(.sRGB) else { return "inherit" }
            return String(
                format: "rgba(%.0f, %.0f, %.0f, %.3f)", rgb.redComponent * 255, rgb.greenComponent * 255, rgb.blueComponent * 255, rgb.alphaComponent)
        }

        static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    #else
        static func css(_ color: UIColor) -> String {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(format: "rgba(%.0f, %.0f, %.0f, %.3f)", red * 255, green * 255, blue * 255, alpha)
        }

        static func open(_ url: URL) { UIApplication.shared.open(url) }
    #endif

    /// If the page's process stops, the page is loaded again, and the text put back in it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("The editor's page stopped; loading it again")
        isReady = false
        shown = ""
        webView.reload()
    }

    /// The page itself is the only thing it loads; anything else is a link, for the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.isFileURL { return .allow }
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) { Self.open(url) }
        return .cancel
    }

    static func makeWebView(_ coordinator: MarkdownWebCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakHandler(coordinator), name: "cecily")
        configuration.websiteDataStore = .nonPersistent()
        let webView = EditorWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.coordinator = coordinator
        #if os(macOS)
            webView.setValue(false, forKey: "drawsBackground")
        #else
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        #endif
        #if os(macOS)
            webView.setAccessibilityIdentifier("MarkdownEditor")
        #else
            webView.accessibilityIdentifier = "MarkdownEditor"
        #endif
        coordinator.webView = webView
        if let page = Bundle.main.url(forResource: "editor", withExtension: "html") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }
}

/// A web view that passes the system's colours to the page again when light or dark changes.
/// On the Mac, while it has the keyboard, the editor's own ⌘ keys go to the page before the
/// menus see them.
final class EditorWebView: WKWebView {
    weak var coordinator: MarkdownWebCoordinator?

    #if os(macOS)
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            coordinator?.sendTheme()
        }

        /// The editor's ⌘ keys: link, bold, italic and code, and ⇧⌘X for strikethrough.
        private static let editorKeys: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
            ("k", .command), ("b", .command), ("i", .command), ("`", .command), ("x", [.command, .shift]),
        ]

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if hasKeyboard, modifiers == .command, key == "\r", let submit = coordinator?.submit {
                submit()
                return true
            }
            if hasKeyboard, Self.editorKeys.contains(where: { $0.key == key && $0.modifiers == modifiers }) {
                keyDown(with: event)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 53, modifiers.isEmpty, let cancel = coordinator?.cancel {
                cancel()
                return
            }
            super.keyDown(with: event)
        }

        /// Whether the page, or a view inside it, has the window's keyboard.
        private var hasKeyboard: Bool {
            guard let responder = window?.firstResponder as? NSView else { return false }
            return responder === self || responder.isDescendant(of: self)
        }
    #else
        override init(frame: CGRect, configuration: WKWebViewConfiguration) {
            super.init(frame: frame, configuration: configuration)
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (view: EditorWebView, _) in
                view.coordinator?.sendTheme()
            }
        }

        required init?(coder: NSCoder) {
            fatalError("Not used from a storyboard")
        }
    #endif
}

/// Holds the coordinator weakly, so the page's message handler doesn't keep it alive.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

#if os(macOS)
    struct MarkdownWebView: NSViewRepresentable {
        @Binding var text: String
        let focusesOnOpen: Bool
        let placeholder: String?
        let links: (any NoteLinking)?
        let noteID: UUID?
        let takeFiles: (([PastedFile]) -> Void)?
        let look: MarkdownWebCoordinator.Look
        let submit: (() -> Void)?
        let cancel: (() -> Void)?

        func makeCoordinator() -> MarkdownWebCoordinator { MarkdownWebCoordinator(text: $text) }

        func makeNSView(context: NSViewRepresentableContext<Self>) -> WKWebView {
            context.coordinator.focusesOnOpen = focusesOnOpen
            context.coordinator.placeholder = placeholder
            context.coordinator.links = links
            context.coordinator.noteID = noteID
            context.coordinator.takeFiles = takeFiles
            context.coordinator.look = look
            context.coordinator.submit = submit
            context.coordinator.cancel = cancel
            return MarkdownWebCoordinator.makeWebView(context.coordinator)
        }

        func updateNSView(_ webView: WKWebView, context: NSViewRepresentableContext<Self>) {
            context.coordinator.text = $text
            context.coordinator.links = links
            context.coordinator.noteID = noteID
            context.coordinator.takeFiles = takeFiles
            context.coordinator.submit = submit
            context.coordinator.cancel = cancel
            if context.coordinator.look != look {
                context.coordinator.look = look
                context.coordinator.sendTheme()
            }
            context.coordinator.send(text)
        }
    }
#else
    struct MarkdownWebView: UIViewRepresentable {
        @Binding var text: String
        let focusesOnOpen: Bool
        let placeholder: String?
        let links: (any NoteLinking)?
        let noteID: UUID?
        let takeFiles: (([PastedFile]) -> Void)?
        let look: MarkdownWebCoordinator.Look
        let submit: (() -> Void)?
        let cancel: (() -> Void)?

        func makeCoordinator() -> MarkdownWebCoordinator { MarkdownWebCoordinator(text: $text) }

        func makeUIView(context: UIViewRepresentableContext<Self>) -> WKWebView {
            context.coordinator.focusesOnOpen = focusesOnOpen
            context.coordinator.placeholder = placeholder
            context.coordinator.links = links
            context.coordinator.noteID = noteID
            context.coordinator.takeFiles = takeFiles
            context.coordinator.look = look
            context.coordinator.submit = submit
            context.coordinator.cancel = cancel
            return MarkdownWebCoordinator.makeWebView(context.coordinator)
        }

        func updateUIView(_ webView: WKWebView, context: UIViewRepresentableContext<Self>) {
            context.coordinator.text = $text
            context.coordinator.links = links
            context.coordinator.noteID = noteID
            context.coordinator.takeFiles = takeFiles
            context.coordinator.submit = submit
            context.coordinator.cancel = cancel
            if context.coordinator.look != look {
                context.coordinator.look = look
                context.coordinator.sendTheme()
            }
            context.coordinator.send(text)
        }
    }
#endif
