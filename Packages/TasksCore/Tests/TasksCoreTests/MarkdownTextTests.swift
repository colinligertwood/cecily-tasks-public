import Testing

@testable import TasksCore

/// Notes' Markdown as one line of plain text, for previews and search.
struct MarkdownTextTests {
    @Test(arguments: [
        ("- [ ] **Measure** the walls", "Measure the walls"),
        ("- [x] Passports", "Passports"),
        ("* Bread\n+ Milk\n- Eggs", "Bread Milk Eggs"),
        ("1. First\n2) Second", "First Second"),
        ("# Kitchen\n## Quotes", "Kitchen Quotes"),
        ("> A quote\n> > nested", "A quote nested"),
        ("An *italic* and _other_ word", "An italic and other word"),
        ("A __strong__ ~~old~~ `code` word", "A strong old code word"),
        ("See [the plan](https://example.com/plan) and ![photo](a.png)", "See the plan and photo"),
        ("Check the excess\n\n<https://example.com/policy>", "Check the excess https://example.com/policy"),
        ("2 * 3 * 4, file_name_here", "2 * 3 * 4, file_name_here"),
        ("  \n\n  ", ""),
    ])
    func leavesTheWordsWithoutTheSymbols(markdown: String, plain: String) {
        #expect(MarkdownText.plain(markdown) == plain)
    }
}
