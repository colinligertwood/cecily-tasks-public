import Foundation

/// A web link pasted into notes on its own, made into a Markdown link with the page's title.
public enum WebLinkTitle {
    /// The URL `text` is, when it's one web address and nothing else.
    public static func pastedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
            ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil
        else { return nil }
        return url
    }

    /// The page's title from its HTML: its `og:title`, or else its `<title>`, with entities read
    /// and spaces collapsed. Nil when it has neither, or they're empty.
    public static func title(fromHTML html: String) -> String? {
        let candidates = [
            html.firstMatch(of: /(?is)<meta\s[^>]*property\s*=\s*["']og:title["'][^>]*content\s*=\s*"([^"]*)"/).map { String($0.output.1) },
            html.firstMatch(of: /(?is)<meta\s[^>]*content\s*=\s*"([^"]*)"[^>]*property\s*=\s*["']og:title["']/).map { String($0.output.1) },
            html.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/).map { String($0.output.1) },
        ]
        for candidate in candidates.compactMap({ $0 }) {
            let text = decodeEntities(candidate).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Fetches the page at `url` with `load` and gives its title, or nil when it can't be read.
    public static func fetchTitle(_ url: URL, load: @Sendable (URL) async throws -> Data) async -> String? {
        guard let data = try? await load(url) else { return nil }
        let html = String(decoding: data.prefix(512 * 1024), as: UTF8.self)
        return title(fromHTML: html)
    }

    static func decodeEntities(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…"]
        return text.replacing(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/) { match in
            let name = String(match.output.1)
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
            }
            if name.hasPrefix("#") {
                return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
            }
            return named[name.lowercased()] ?? String(match.output.0)
        }
    }
}
