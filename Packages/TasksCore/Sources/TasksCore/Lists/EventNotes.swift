import Foundation

/// A calendar event's notes, which some calendars keep as HTML, as a web page to show them.
public enum EventNotes {
    /// Whether `text` is HTML: it has tags such as `<p>` or `<br>`, or entities such as `&nbsp;`.
    public static func isHTML(_ text: String) -> Bool {
        text.contains(/<\/?[a-zA-Z][a-zA-Z0-9]*(\s[^>]*)?\/?>/) || text.contains(/&(nbsp|amp|lt|gt|quot|#\d+);/)
    }

    /// The web addresses and email addresses written out in `text`, with where they are.
    public static func links(in text: String) -> [(range: NSRange, url: URL)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            match.url.map { (match.range, $0) }
        }
    }

    /// `html` without its images.
    public static func withoutImages(_ html: String) -> String {
        html.replacing(/<img\b[^>]*>/.ignoresCase(), with: "")
    }

    /// `html` with its links' targets taken out, so a link that would open a new window opens
    /// like any other.
    public static func withoutLinkTargets(_ html: String) -> String {
        html.replacing(/<a\b[^>]*>/.ignoresCase()) { tag in
            String(tag.output).replacing(/\s+target\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/.ignoresCase(), with: "")
        }
    }

    /// The notes as a web page in the system's font, following light and dark, with the colours,
    /// fonts and sizes they set left to the system, apart from headings. HTML notes keep their
    /// lists, tables and links, without their images or links' targets, and with the web and
    /// email addresses written out in their text as links, and their loose text keeping its
    /// lines; plain ones keep their lines, with the web
    /// and email addresses in them as links. Nothing outside the page can load.
    public static func page(_ notes: String) -> String {
        let body = isHTML(notes) ? keepingLooseText(linkingAddresses(withoutLinkTargets(withoutImages(notes)))) : plainBody(notes)
        return """
            <!doctype html>
            <html><head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <meta name="color-scheme" content="light dark">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            html, body { margin: 0; padding: 0; background: transparent; color: CanvasText; font: -apple-system-body; overflow-wrap: anywhere; }
            body * { font-family: inherit !important; color: inherit !important; background: transparent !important; }
            body *:not(h1, h2, h3, h4, h5, h6) { font-size: inherit !important; }
            a, a * { color: LinkText !important; }
            p { margin: 0 0 0.6em; }
            ul, ol { margin: 0.2em 0 0.6em; padding-left: 1.4em; }
            table { border-collapse: collapse; }
            td, th { padding: 2px 8px 2px 0; vertical-align: top; text-align: left; }
            img { display: none; }
            .loose { white-space: pre-wrap; }
            </style>
            </head><body>
            \(body)
            </body></html>
            """
    }

    /// `html` with the web and email addresses written out in its text made into links, except
    /// in text that's already a link's, or in a `<style>`, `<script>` or `<title>`.
    public static func linkingAddresses(_ html: String) -> String {
        mappingText(html) { text, place in
            place.isInLink || place.isSkipped ? text : linked(text, escaping: false)
        }
    }

    /// `html` with its loose text, that isn't in any element but the document's own, kept as it's
    /// written, with its line breaks and spaces, and wrapped at the page's edge; but with each run
    /// of line breaks as one. Text that's only spaces and line breaks is left out of it.
    public static func keepingLooseText(_ html: String) -> String {
        mappingText(html) { text, place in
            guard place.depth == 0, !place.isSkipped, !text.allSatisfy(\.isWhitespace) else { return text }
            return "<span class=\"loose\">\(withoutExtraLineBreaks(text))</span>"
        }
    }

    /// `text` with `\r\n` and `\r` as `\n`, and each run of line breaks as one.
    static func withoutExtraLineBreaks(_ text: String) -> String {
        text.replacing("\r\n", with: "\n").replacing("\r", with: "\n").replacing(/\n{2,}/, with: "\n")
    }

    /// Where a run of text is in its HTML.
    private struct TextPlace {
        /// How many elements it's in, not counting `<html>`, `<head>` and `<body>`.
        var depth = 0
        var isInLink = false
        /// In a `<style>`, `<script>` or `<title>`, whose text isn't shown as text.
        var isSkipped = false
    }

    /// The elements with no closing tag.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]

    /// `html` with each run of text between its tags replaced by what `transform` makes of it.
    private static func mappingText(_ html: String, _ transform: (String, TextPlace) -> String) -> String {
        var result = ""
        var place = TextPlace()
        var linkDepth = 0
        var rest = html[...]
        while !rest.isEmpty {
            if let tag = rest.prefixMatch(of: /<(\/?)([a-zA-Z][a-zA-Z0-9]*)[^>]*?(\/?)>/) {
                let name = tag.output.2.lowercased()
                let isClosing = !tag.output.1.isEmpty
                let isSelfClosing = !tag.output.3.isEmpty || voidElements.contains(name)
                if !["html", "head", "body"].contains(name), !isSelfClosing {
                    place.depth = max(0, place.depth + (isClosing ? -1 : 1))
                }
                if name == "a", !isSelfClosing {
                    linkDepth = max(0, linkDepth + (isClosing ? -1 : 1))
                    place.isInLink = linkDepth > 0
                }
                if ["style", "script", "title"].contains(name) { place.isSkipped = !isClosing }
                result += tag.output.0
                rest = rest[tag.range.upperBound...]
            } else {
                let end = rest.dropFirst().firstIndex(of: "<") ?? rest.endIndex
                result += transform(String(rest[..<end]), place)
                rest = rest[end...]
            }
        }
        return result
    }

    /// `text` with its addresses as links. Plain text is escaped as well; HTML text already is,
    /// so a link's own text stands as its address when it has a scheme.
    private static func linked(_ text: String, escaping: Bool) -> String {
        let nsText = text as NSString
        func escape(_ text: String) -> String { escaping ? escaped(text) : text }
        var html = ""
        var at = 0
        for link in links(in: text) {
            let written = nsText.substring(with: link.range)
            let href = !escaping && written.contains(/^[a-zA-Z][a-zA-Z0-9+.-]*:/) ? written : escaped(link.url.absoluteString)
            html += escape(nsText.substring(with: NSRange(location: at, length: link.range.location - at)))
            html += "<a href=\"\(href)\">\(escape(written))</a>"
            at = link.range.location + link.range.length
        }
        return html + escape(nsText.substring(from: at))
    }

    /// Plain notes as HTML: escaped, with their line breaks, and their addresses as links.
    private static func plainBody(_ text: String) -> String {
        linked(text.trimmingCharacters(in: .whitespacesAndNewlines), escaping: true).replacing("\n", with: "<br>\n")
    }

    private static func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;").replacing("\"", with: "&quot;")
    }
}
