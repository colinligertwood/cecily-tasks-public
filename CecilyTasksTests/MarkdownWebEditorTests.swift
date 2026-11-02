import Foundation
import SwiftUI
import Testing
import WebKit

@testable import CecilyTasks

/// The Markdown editor in its web view: it opens, and text goes in and comes out exactly as it was.
@MainActor
final class EditorUnderTest {
    var text = ""
    let coordinator: MarkdownWebCoordinator
    let webView: WKWebView

    init() async throws {
        var box: EditorUnderTest!
        let text = Binding<String>(get: { box?.text ?? "" }, set: { box?.text = $0 })
        coordinator = MarkdownWebCoordinator(text: text)
        webView = MarkdownWebCoordinator.makeWebView(coordinator)
        webView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        box = self
        for _ in 0..<100 {
            if try await isReady(), coordinator.webView != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // The page says it's ready once it has set itself up; then the app's text is in it.
        try await Task.sleep(for: .milliseconds(100))
    }

    func isReady() async throws -> Bool {
        (try await webView.evaluateJavaScript("typeof window.cecily === 'object'")) as? Bool ?? false
    }

    @discardableResult
    func run(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    func stored() async throws -> String { try await run("return cecily.getText()") as? String ?? "" }
    func set(_ text: String) async throws { try await run("cecily.setText(text)", ["text": text]) }

    /// Lets the page's messages back to the app arrive.
    func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
}

@MainActor
@Suite(.serialized)
struct MarkdownWebEditorTests {
    @Test func itOpensQuickly() async throws {
        var times: [Duration] = []
        for _ in 0..<3 {
            MarkdownWebEditorTiming.lastOpen = nil
            _ = try await EditorUnderTest()
            times.append(try #require(MarkdownWebEditorTiming.lastOpen))
        }
        #expect(times[1] < .seconds(2) && times[2] < .seconds(2), "once the web engine's running")
    }

    @Test(arguments: [
        "Plain words", "# Kitchen refit\n- [ ] Email Sam\n> quote", "A \\*literal\\* star and C:\\\\path", "**bold** _soft_ `code` [l](https://a.b)",
        "Emoji 😀 and accents é", "",
    ])
    func textGoesInAndComesOutExactly(_ text: String) async throws {
        let editor = try await EditorUnderTest()
        try await editor.set(text)
        #expect(try await editor.stored() == text)
    }

    @Test func aChangeFromTheAppShowsInTheEditor() async throws {
        let editor = try await EditorUnderTest()
        editor.coordinator.send("from the other device")
        try await editor.settle()
        #expect(try await editor.stored() == "from the other device")
    }
}
