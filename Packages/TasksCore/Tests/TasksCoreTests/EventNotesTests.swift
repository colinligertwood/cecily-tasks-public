import Foundation
import Testing

@testable import TasksCore

/// Telling a calendar event's HTML notes from plain ones, and making a page of them.
struct EventNotesTests {
    @Test(arguments: [
        ("<p>Agenda</p>", true),
        ("Line one<br>Line two", true),
        ("<div class=\"x\">Join</div>", true),
        ("Fish &amp; chips", true),
        ("Bring the 2 < 3 slide", false),
        ("Email <noor@example.com>", false),
        ("Plain notes\nwith lines", false),
    ])
    func tellsHTMLFromPlainText(text: String, isHTML: Bool) {
        #expect(EventNotes.isHTML(text) == isHTML)
    }

    @Test func webAndEmailAddressesAreFound() {
        let text = "Join at https://meet.example.com/abc-123 or write to noor@example.com."
        let links = EventNotes.links(in: text)
        #expect(links.map(\.url.absoluteString) == ["https://meet.example.com/abc-123", "mailto:noor@example.com"])
        #expect(links.map { (text as NSString).substring(with: $0.range) } == ["https://meet.example.com/abc-123", "noor@example.com"])
    }

    @Test func htmlNotesKeepTheirMarkupWithoutImages() {
        let page = EventNotes.page("<ul><li>Hiring</li></ul><IMG src=\"https://example.com/a.png\"/>")
        #expect(page.contains("<ul><li>Hiring</li></ul>") && !page.contains("example.com/a.png"))
        #expect(page.contains("default-src 'none'"), "nothing outside the page loads")
    }

    @Test func linksLoseTheirTargets() {
        let html =
            #"<p class="x" target="keep"><a href="https://teams.example.com/join" target="_blank" rel="noreferrer">Join</a> <A TARGET='_new' href="https://example.com">More</A> <a href=x target=_blank>Bare</a></p>"#
        #expect(
            EventNotes.withoutLinkTargets(html)
                == #"<p class="x" target="keep"><a href="https://teams.example.com/join" rel="noreferrer">Join</a> <A href="https://example.com">More</A> <a href=x>Bare</a></p>"#
        )
    }

    @Test func addressesWrittenInHTMLBecomeLinks() {
        let html =
            #"<style>a { color: red }</style><p>Join: https://teams.example.com/l/meetup?a=1&amp;b=2<br>Or <a href="https://example.com/x">https://example.com/x</a>, or write to noor@example.com</p>"#
        #expect(
            EventNotes.linkingAddresses(html)
                == #"<style>a { color: red }</style><p>Join: <a href="https://teams.example.com/l/meetup?a=1&amp;b=2">https://teams.example.com/l/meetup?a=1&amp;b=2</a><br>Or <a href="https://example.com/x">https://example.com/x</a>, or write to <a href="mailto:noor@example.com">noor@example.com</a></p>"#
        )
    }

    @Test func looseTextKeepsItsLines() {
        let html = "<html><body>Agenda:\n  1. Hiring\n  2. Rota\n<p>In a\nparagraph</p>\n<br/>After <b>bold</b>\n</body></html>"
        #expect(
            EventNotes.keepingLooseText(html)
                == "<html><body><span class=\"loose\">Agenda:\n  1. Hiring\n  2. Rota\n</span><p>In a\nparagraph</p>\n<br/><span class=\"loose\">After </span><b>bold</b>\n</body></html>"
        )
    }

    @Test func looseTextHasOneLineBreakWhereThereWereMore() {
        #expect(
            EventNotes.withoutExtraLineBreaks("Join:\r\n\r\n  https://example.com\rOr dial in\n\n\nby phone\n")
                == "Join:\n  https://example.com\nOr dial in\nby phone\n")
        #expect(
            EventNotes.keepingLooseText("<p>Agenda</p>\r\n\r\nJoin here\r\n\r\nOr dial in<p>More</p>")
                == "<p>Agenda</p><span class=\"loose\">\nJoin here\nOr dial in</span><p>More</p>")
    }

    @Test func plainNotesAreEscapedWithTheirLinesAndLinks() {
        let page = EventNotes.page("  Bring the 2 < 3 slide\nJoin at https://meet.example.com/abc  ")
        #expect(
            page.contains("Bring the 2 &lt; 3 slide<br>\nJoin at <a href=\"https://meet.example.com/abc\">https://meet.example.com/abc</a>\n</body>"))
    }
}
