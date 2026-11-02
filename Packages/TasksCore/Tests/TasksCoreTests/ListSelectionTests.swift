import Testing

@testable import TasksCore

struct ListSelectionTests {
    @Test(
        arguments: [
            // Still there: kept, the others dropped.
            (["b", "c"], ["a", "b", "c", "d"], ["a", "b", "d"], ["b"]),
            // Gone: the row after the last of them.
            (["b"], ["a", "b", "c", "d"], ["a", "c", "d"], ["c"]),
            (["b", "c"], ["a", "b", "c", "d"], ["a", "d"], ["d"]),
            // The rows right after went too: the next one still there.
            (["b"], ["a", "b", "c", "d"], ["a", "d"], ["d"]),
            // At the end: the one before.
            (["d"], ["a", "b", "c", "d"], ["a", "b", "c"], ["c"]),
            // Everything gone.
            (["a"], ["a"], [], []),
            // Nothing selected stays so.
            ([], ["a", "b"], ["b"], []),
            // A row moved within the list keeps its selection.
            (["b"], ["a", "b", "c"], ["b", "a", "c"], ["b"]),
        ] as [([String], [String], [String], [String])])
    func keptAfterAChange(_ selected: [String], _ before: [String], _ now: [String], _ expected: [String]) {
        #expect(ListSelection.kept(Set(selected), before: before, now: now) == Set(expected))
    }
}
