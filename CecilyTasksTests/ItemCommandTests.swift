import Foundation
import SwiftData
import Testing

@testable import CecilyTasks
@testable import TasksCore

/// The Item menu's commands: when they apply, and moving an item from wherever it is.
@MainActor
struct ItemCommandTests {
    let model: AppModel

    init() throws {
        model = try Store.open().get().model
        model.undoManager = UndoManager()
    }

    func item(_ title: String, _ bucket: Bucket, kind: ItemKind = .action) -> Item {
        let item = Item(title: title, bucket: bucket)
        item.kind = kind
        model.context.insert(item)
        model.save()
        return item
    }

    @Test func nothingAppliesToNothing() {
        #expect(!model.can(.done, []))
        #expect(!model.can(.move(.action), []))
    }

    @Test func theSelectionOrTheOpenItemIsWhatsActedOn() {
        let a = item("A", .inbox)
        let b = item("B", .inbox)
        model.selection = [a.id, b.id]
        #expect(Set(model.commandItems.map(\.id)) == [a.id, b.id])
        model.openItem = b.id
        #expect(model.commandItems.map(\.id) == [b.id])
    }

    @Test func movingFromTheInboxFilesIt() {
        let a = item("A", .inbox)
        model.perform(.move(.someday), [a])
        #expect(a.bucket == .someday)
        #expect(!model.can(.move(.someday), [a]))
    }

    @Test func movingFromSomedayToActionsActivatesIt() {
        let a = item("A", .someday)
        model.perform(.move(.action), [a])
        #expect(a.bucket == .action)
    }

    @Test func movingFromWaitingToActionsTakesItBack() {
        let a = item("A", .waiting)
        a.waitingOn = "Sam"
        model.perform(.move(.action), [a])
        #expect(a.bucket == .action)
    }

    @Test func notesDontGoToActionsOrWaiting() {
        let note = item("Minutes", .reference, kind: .note)
        #expect(!model.can(.move(.action), [note]))
        #expect(!model.can(.move(.waiting), [note]))
        #expect(model.can(.move(.someday), [note]))
    }

    @Test func trashedItemsCanOnlyBePutBack() {
        let a = item("A", .inbox)
        model.perform(.trash, [a])
        #expect(a.bucket == .trash)
        #expect(!model.can(.done, [a]) && !model.can(.move(.action), [a]) && !model.can(.trash, [a]))
        #expect(model.can(.putBack, [a]))
    }

    @Test func doneMarksAndUnmarks() {
        let a = item("A", .action)
        #expect(AppModel.name(of: .done, for: [a]) == "Mark as Done")
        model.perform(.done, [a])
        #expect(a.status == .done)
        #expect(AppModel.name(of: .done, for: [a]) == "Mark as Not Done")
    }

    @Test func hideUntilOpensForOneItem() {
        let a = item("A", .action)
        let b = item("B", .action)
        #expect(!model.can(.hideUntil, [a, b]))
        model.perform(.hideUntil, [a])
        #expect(model.hiding?.id == a.id)
    }

    @Test func movingToWaitingAsksWhoFirst() {
        let a = item("Quote", .inbox)
        model.perform(.move(.waiting), [a])
        #expect(a.bucket == .inbox)
        #expect(model.askingWaitingFor?.map(\.id) == [a.id])
        model.moveToWaiting([a], for: " Sam ")
        #expect(a.bucket == .waiting && a.waitingOn == "Sam")
        #expect(AppModel.name(of: .move(.waiting), for: [a]) == "Move to Waiting…")
    }

    @Test func detailsOpenAsTheInspectorShowsThem() {
        let a = item("Call", .action)
        let b = item("Email", .action)
        model.selection = [a.id]
        #expect(model.canEdit(.title) && model.canEdit(.field(.waitingFor)) && model.canEdit(.field(.due)))
        model.selection = [a.id, b.id]
        #expect(!model.canEdit(.title) && !model.canEdit(.field(.waitingFor)))
        #expect(model.canEdit(.field(.area)) && model.canEdit(.field(.timeEstimate)))
        model.selection = []
        #expect(!model.canEdit(.field(.area)))
    }

    @Test func aDetailOpensInTheInspectorForTheOpenItem() {
        let a = item("A", .action)
        let b = item("B", .action)
        model.selection = [a.id]
        model.openItem = b.id
        model.showsInspector = false
        model.edit(.field(.due))
        #expect(model.selection == [b.id])
        #expect(model.showsInspector)
        #expect(model.detailRequest == .field(.due))
    }

    @Test func rowsMoveWithinThePartOfTheListShowing() {
        let a = item("A", .action)
        let b = item("B", .action)
        let c = item("C", .action)
        a.sortOrder = 0
        b.sortOrder = 1
        c.sortOrder = 2
        model.arrangeableRows = [ListRow.rows([a, b], doneSince: nil), ListRow.rows([c], doneSince: nil)]
        #expect(model.can(.arrange(.up), [b]) && !model.can(.arrange(.up), [a]))
        #expect(!model.can(.arrange(.down), [b, c]), "in two parts")
        model.perform(.arrange(.up), [b])
        #expect([a, b].sorted(by: Item.inListOrder).map(\.title) == ["B", "A"])
        #expect(model.undoManager?.undoActionName == "Move Up")
        model.openItem = a.id
        #expect(!model.can(.arrange(.down), [b]), "not while an item is open")
        model.openItem = nil
        model.arrangeableRows = []
        #expect(!model.can(.arrange(.down), [b]), "not in a list whose rows don't move")
    }

    @Test func rowsPutUnderATaskSettleUnderItAndCanBeUndone() {
        let task = item("Paint the shed", .action)
        let moved = item("Buy brushes", .action)
        task.sortOrder = 0
        moved.sortOrder = 1
        model.arrangeableRows = [ListRow.rows([task, moved], doneSince: nil)]
        model.selection = [moved.id]
        model.perform(.arrange(.intoAbove), [moved])
        #expect(moved.parent === task)
        #expect(model.settling == Settling(task: task.id, moved: [moved.id], name: "Move Into Task Above"))
        #expect(model.keptWhileSettling == [task.id])
        #expect(model.selection == [moved.id])
        model.undoSettling()
        #expect(moved.parent == nil)
        #expect(model.settling == nil)
    }

    @Test func droppingIntoAnotherContextMovesItThere() throws {
        let calls = Context(name: "Calls")
        let errands = Context(name: "Errands")
        model.context.insert(calls)
        model.context.insert(errands)
        let a = item("A", .action)
        a.contexts = [calls]
        let b = item("B", .action)
        b.contexts = [errands]
        let groups = ActionsList.groups([a, b], by: .context, today: model.today, doneSince: nil)
        let sections = groups.map { ListRow.rows($0.items, doneSince: nil) }
        model.arrangeableRows = sections
        let from = try #require(groups.first { $0.items.contains(a) })
        let into = try #require(groups.firstIndex { $0.items.contains(b) })
        let payload = model.dragged(a, from: from.dropGroup)
        model.drop([payload], at: 0, in: sections[into], into: groups[into].dropGroup)
        #expect(a.contexts?.map(\.name) == ["Errands"])
        #expect(model.undoManager?.undoActionName == "Move")
    }

    @Test func aGroupThatCantBeGivenRowsTakesNoneFromAnother() {
        let a = item("A", .inbox)
        let b = item("B", .inbox)
        a.sortOrder = 1
        b.sortOrder = 0
        let today = DropGroup(id: "inbox-today", headings: [])
        let earlier = DropGroup(id: "inbox-earlier", headings: [])
        let rows = ListRow.rows([b], doneSince: nil)
        model.arrangeableRows = [ListRow.rows([a], doneSince: nil), rows]
        let payload = model.dragged(a, from: today)
        model.drop([payload], at: 0, in: rows, into: earlier)
        #expect(a.sortOrder == 1 && b.sortOrder == 0)
    }

    @Test func aListSortedOtherwiseCantBeReorderedByHand() {
        let a = item("A", .waiting)
        let b = item("B", .waiting)
        a.sortOrder = 0
        b.sortOrder = 1
        model.arrangeableRows = [ListRow.rows([a, b], doneSince: nil)]
        model.arrangeableReorders = false
        #expect(!model.can(.arrange(.up), [b]))
        #expect(model.can(.arrange(.intoAbove), [b]))
    }
}
