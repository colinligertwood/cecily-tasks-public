import SwiftUI
import TasksCore
import Testing

@testable import CecilyTasks

/// The keyboard's commands: one key each, every shortcut in a job holding the job's keys, and the
/// card showing the key tapped.
@MainActor
struct KeyCommandTests {
    @Test func noKeyIsUsedTwice() {
        let chords = KeyCommand.all.compactMap(\.chord).map(KeyCommand.label)
        #expect(Set(chords).count == chords.count)
        let bare = KeyCommand.all.compactMap(\.bare)
        #expect(Set(bare).count == bare.count)
        #expect(Set(KeyCommand.all.map(\.id)).count == KeyCommand.all.count)
    }

    @Test func everyShortcutInAJobHoldsItsKeys() {
        for command in KeyCommand.all {
            guard let held = command.job.held else { continue }
            #expect(command.chord?.modifiers == held, "\(command.name)")
        }
    }

    @Test func everyCommandHasAKey() {
        for command in KeyCommand.all {
            #expect(!command.keys.isEmpty, "\(command.name)")
        }
    }

    @Test func theCardShowsTheKeyTapped() {
        #expect(KeyCommand.hideUntil.tapped == ["H"])
        #expect(KeyCommand.toActions.tapped == ["3"])
        #expect(KeyCommand.inspector.tapped == ["I"])
        #expect(KeyCommand.newItem.tapped == ["⌘", "N"])
        #expect(KeyCommand.trash.tapped == ["⌫"])
        #expect(KeyCommand.upDown.tapped == ["↑", "↓"])
    }

    @Test func voiceOverReadsTheWholeChord() {
        #expect(KeyCommand.hideUntil.spoken == "Shift Command H, Hide until")
        #expect(KeyCommand.trash.spoken == "Delete, Trash")
    }

    @Test func chordsAsShown() {
        #expect(KeyCommand.label(KeyboardShortcut("n", modifiers: [.command, .shift])) == "⇧⌘N")
        #expect(KeyCommand.label(KeyboardShortcut("i", modifiers: [.command, .option])) == "⌥⌘I")
        #expect(KeyCommand.label(KeyboardShortcut(.return, modifiers: .command)) == "⌘↩")
    }

    @Test func onlyDeleteWorksOnItsOwn() {
        #expect(KeyCommand.bare(KeyCommand.deleteKey, modifiers: [])?.action == .trash)
        #expect(KeyCommand.bare(KeyCommand.deleteKey, modifiers: .command) == nil)
        for letter in ["1", "3", "7", "n", "t", "a", "s", " ", "?", "/"] {
            #expect(KeyCommand.bare(letter, modifiers: []) == nil, "\(letter)")
        }
    }

    @Test func theListsNumbersFollowTheSidebar() {
        #expect(KeyCommand.lists.map(\.page) == Page.allCases)
        #expect(KeyCommand.lists.compactMap(\.chord).map(KeyCommand.label) == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7"])
    }

    @Test func theAreasAreOneRowOnTheCard() {
        #expect(KeyCommand.areas.tapped == ["1–9"])
        #expect(KeyCommand.areas.spoken == "Option Command 1–9, Area")
        #expect(KeyCommand.label(KeyCommand.area(4)) == "⌥⌘4")
        #expect(KeyCommand.allAreas.tapped == ["0"])
    }

    @Test func arrangingWorksOnlyInLists() {
        #expect(KeyCommand.moveUp.tapped == ["↑", "↓"])
        #expect(KeyCommand.listOnly(.downArrow, modifiers: [.control, .command])?.action == .arrange(.down))
        #expect(KeyCommand.listOnly(.rightArrow, modifiers: [.control, .command])?.action == .arrange(.intoAbove))
        #expect(KeyCommand.listOnly(.downArrow, modifiers: .command) == nil, "⌘ and the arrows move the cursor")
        #expect(KeyCommand.listOnly(.leftArrow, modifiers: [.command, .shift]) == nil)
        #expect(KeyCommand.listOnly(.upArrow, modifiers: []) == nil)
        #expect(KeyCommand.listOnly(KeyEquivalent("3"), modifiers: [.control, .command]) == nil, "a chord that works everywhere")
        #expect(!KeyCommand.onCard.contains { $0.id == KeyCommand.moveDown.id })
    }

    @Test func movingUsesTheListsNumber() {
        #expect(KeyCommand.toActions.chord.map(KeyCommand.label) == "⌃⌘3")
        #expect(KeyCommand.lists[2].page == .actions)
        #expect(KeyCommand.toReference.chord.map(KeyCommand.label) == "⌃⌘6")
        #expect(KeyCommand.toWaiting.action == .move(.waiting))
    }

    @Test func detailsFollowTheInspector() {
        let details = KeyCommand.all.filter { $0.job == .details }.compactMap(\.detail)
        #expect(
            details == [
                .title, .field(.area), .field(.project), .field(.scheduled), .field(.due), .field(.repeats), .field(.hideUntil), .field(.contexts),
                .field(.timeEstimate), .field(.energy), .field(.waitingFor), .field(.followUp),
            ])
        #expect(KeyCommand.time.tapped == ["T"] && KeyCommand.energy.tapped == ["Y"])
    }
}
