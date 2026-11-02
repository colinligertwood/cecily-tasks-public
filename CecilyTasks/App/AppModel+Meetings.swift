import Foundation
import SwiftData
import TasksCore

extension AppModel {
    /// Links `note` to the calendar event series `seriesID`, or with nil unlinks the series, as a
    /// decision that can be undone.
    func linkMeeting(_ note: Item?, to seriesID: String) {
        record(AgendaEvents.link(note, to: seriesID, in: context), named: note == nil ? "Unlink Event" : "Link Event")
    }

    /// Makes an item in Reference for the event, named like it and linked to it, and opens it unless
    /// `opening` is false.
    @discardableResult
    func newEventItem(for event: CalendarEvent, opening: Bool = true) -> Item {
        let made = AgendaEvents.newMeetingNote(for: event, in: context)
        record(made.undo, named: "New Item")
        if opening { openItem = made.note.id }
        return made.note
    }

    /// Starts a new subtask for the event, under `note` once it's linked to the event, or
    /// under a new note for it.
    func newSubtask(at event: CalendarEvent, under note: Item?) {
        if let note {
            linkMeeting(note, to: event.seriesID)
            newSubItem(of: note)
        } else {
            newSubItem(of: newEventItem(for: event, opening: false))
        }
    }
}
