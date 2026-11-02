import Foundation

/// Notes' Markdown, as one line of plain text for a row's preview and for search: the words,
/// without the symbols that format them.
public enum MarkdownText {
    /// `markdown` with its lines joined by spaces, and without list and task markers, heading and
    /// quote marks, emphasis, code marks, and links' addresses (a link's text stays, and an
    /// autolink's address).
    public static func plain(_ markdown: String) -> String {
        markdown.split(whereSeparator: \.isNewline)
            .map { plainLine(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func plainLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = text.replacing(/^#{1,6}\s+/, with: "")
        text = text.replacing(/^(>\s?)+/, with: "")
        text = text.replacing(/^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/, with: "")
        text = text.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
        text = text.replacing(/<((?:https?|mailto):[^>\s]+)>/) { String($0.output.1) }
        text = text.replacing(/(\*\*|__)(.+?)\1/) { String($0.output.2) }
        text = text.replacing(/(^|[^\w*])[*_]([^\s*_](?:[^*_]*[^\s*_])?)[*_](?![\w*])/) { String($0.output.1) + String($0.output.2) }
        text = text.replacing(/~~(.+?)~~/) { String($0.output.1) }
        text = text.replacing(/`([^`]*)`/) { String($0.output.1) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
