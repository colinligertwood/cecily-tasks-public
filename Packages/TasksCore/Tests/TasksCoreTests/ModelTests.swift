import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct ModelTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
    }

    @Test func aNewItemStartsInTheInboxOpen() throws {
        context.insert(Item(title: "Email Sam"))
        try context.save()
        let item = try #require(try context.fetch(FetchDescriptor<Item>()).first)
        #expect(item.bucket == .inbox && item.status == .open && item.kind == .action && item.source == .quickAdd)
        #expect(item.project == nil && item.contexts?.isEmpty == true)
    }

    @Test func choicesStoreTheirRawValues() {
        let item = Item()
        item.bucket = .waiting
        item.timeEstimate = .twoHoursOrMore
        item.energy = .low
        #expect(item.bucketRaw == "waiting" && item.timeEstimateRaw == "2h+" && item.energyRaw == "low")
        item.bucketRaw = "a bucket from a newer version"
        #expect(item.bucket == .inbox)
    }

    @Test func deletingAProjectDeletesItsItems() throws {
        let project = context.insertProject("Kitchen refitted")
        let item = Item(title: "Measure the walls", bucket: .action)
        context.insert(item)
        item.parent = project
        try context.save()
        context.delete(project)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Item>()) == 0)
    }

    @Test func deletingAnItemDeletesItsSubItemsAttachmentsAndRepeat() throws {
        let item = Item(title: "Pack for the trip")
        context.insert(item)
        let child = Item(title: "Passports")
        context.insert(child)
        child.parent = item
        let attachment = TasksCore.Attachment(filename: "list.pdf", contentType: "com.adobe.pdf", data: Data([1, 2, 3]))
        context.insert(attachment)
        attachment.item = item
        let repetition = Repetition()
        context.insert(repetition)
        item.repeatRule = repetition
        try context.save()
        context.delete(item)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Item>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TasksCore.Attachment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Repetition>()) == 0)
    }

    @Test func anItemCanHaveSeveralContexts() throws {
        try TasksSchema.seed(context)
        let contexts = try context.fetch(FetchDescriptor<Context>(sortBy: [SortDescriptor(\.sortOrder)]))
        let item = Item(title: "Call the bank")
        context.insert(item)
        item.contexts = [contexts[0], contexts[2]]
        try context.save()
        #expect(Set(item.contexts?.map(\.name) ?? []) == ["Calls", "Meetings"])
        #expect(contexts[0].items?.map(\.title) == ["Call the bank"])
    }

    @Test func aRepetitionHoldsARepeatRule() throws {
        let repetition = Repetition()
        let rule = RepeatRule(
            .schedule(try Recurrence(rrule: "FREQ=MONTHLY;BYDAY=-1FR")), showDaysBefore: 3, endDate: LocalDate(2027, 12, 31), remainingCount: 4)
        repetition.rule = rule
        #expect(repetition.modeRaw == "schedule" && repetition.rrule == "FREQ=MONTHLY;BYDAY=-1FR")
        #expect(repetition.rule == rule)
        repetition.rule = RepeatRule(.afterCompletion(value: 2, unit: .week))
        #expect(repetition.rule == RepeatRule(.afterCompletion(value: 2, unit: .week)))
        repetition.modeRaw = "schedule"
        repetition.rrule = "not a rule"
        #expect(repetition.rule == nil)
    }

    @Test func dateOnlyFieldsAreMidnightUTC() {
        let day = LocalDate(2026, 10, 25)
        #expect(day.storedDate == Date(timeIntervalSince1970: 1_792_886_400))
        #expect(LocalDate(day: day.storedDate) == day)
    }

    @Test func seedingHidesRetiredBuiltInsNobodyChangedOrUsed() throws {
        func retired(_ number: Int, _ name: String) -> Context {
            let made = Context(name: name)
            made.id = UUID(uuidString: "C0000000-0000-4000-8000-00000000000\(number)")!
            made.isBuiltIn = true
            made.modifiedAt = made.createdAt
            context.insert(made)
            return made
        }
        let computer = retired(1, "Computer")
        let home = retired(4, "Home")
        let office = retired(5, "Office")
        let item = Item(title: "Fix the tap")
        context.insert(item)
        item.contexts = [home]
        office.name = "Studio"
        office.modifiedAt = .now
        try context.save()
        try TasksSchema.seed(context)
        #expect(computer.isHidden)
        #expect(!home.isHidden && !office.isHidden)
    }

    @Test(arguments: ["Anywhere", "Out and About"])
    func seedingFoldsAnywhereIntoNoContextUnlessRenamed(name: String) throws {
        let anywhere = Context(name: name)
        anywhere.id = Context.anywhereID
        anywhere.isBuiltIn = true
        anywhere.modifiedAt = anywhere.createdAt
        context.insert(anywhere)
        let calls = Context(name: "Calls")
        context.insert(calls)
        let both = Item(title: "Ring the plumber", bucket: .action)
        let only = Item(title: "Read the manual", bucket: .action)
        context.insert(both)
        context.insert(only)
        both.contexts = [calls, anywhere]
        only.contexts = [anywhere]
        let before = both.modifiedAt
        try context.save()
        try TasksSchema.seed(context)
        let renamed = name != "Anywhere"
        #expect(anywhere.isHidden == !renamed)
        #expect(both.contexts?.map(\.name).sorted() == (renamed ? ["Calls", name].sorted() : ["Calls"]))
        #expect(only.contexts?.isEmpty == !renamed)
        #expect((both.modifiedAt != before) == !renamed)
    }

    @Test(arguments: [("Agendas", "Meetings"), ("People to see", "People to see")])
    func seedingRenamesAgendasToMeetingsUnlessRenamed(name: String, expected: String) throws {
        let agendas = Context(name: name, symbol: "person.2")
        agendas.id = Context.meetingsID
        agendas.isBuiltIn = true
        agendas.modifiedAt = agendas.createdAt
        context.insert(agendas)
        try context.save()
        try TasksSchema.seed(context)
        #expect(agendas.name == expected)
        #expect((agendas.modifiedAt != agendas.createdAt) == (name == "Agendas"))
        #expect(try context.fetchCount(FetchDescriptor<Context>()) == Context.builtIn.count)
    }

    @Test func seedingMakesTheBuiltInsOnce() throws {
        try TasksSchema.seed(context)
        try TasksSchema.seed(context)
        let contexts = try context.fetch(FetchDescriptor<Context>(sortBy: [SortDescriptor(\.sortOrder)]))
        #expect(contexts.map(\.name) == ["Calls", "Errands", "Meetings"])
        #expect(contexts.allSatisfy { $0.isBuiltIn })
        let settings = try context.fetch(FetchDescriptor<AppSettings>())
        #expect(settings.count == 1 && settings.first?.id == AppSettings.fixedID)
        #expect(settings.first?.weeklyReviewWeekday == 6 && settings.first?.weeklyReviewTime == 15 * 60)
        #expect(settings.first?.dayBoundaryTime == 4 * 60 && settings.first?.dueNotificationTime == 9 * 60)
    }

    /// Every stored property syncs, so nothing is left on one device. To-many relationships sync
    /// from their other side, except an item's contexts, a list on both sides; a repeat rule's owner is
    /// stored on the rule.
    @Test(arguments: SyncModels.all.map { $0.recordType })
    func everyPropertySyncs(_ recordType: String) throws {
        let entityName = recordType == Repetition.recordType ? "Repetition" : recordType
        let entity = try #require(TasksSchema.schema.entities.first { $0.name == entityName })
        var expected = Set(entity.attributes.map(\.name)).subtracting(["id"])
        for relationship in entity.relationships {
            switch (entityName, relationship.name) {
            case ("Item", "contexts"): expected.insert(relationship.name)
            case ("Item", "repeatRule"): break
            default: if relationship.isToOneRelationship { expected.insert(relationship.name) }
            }
        }
        let model = try #require(SyncModels.byType[recordType])
        #expect(Set(model.fieldNames) == expected)
    }

    @Test func everyRelationshipHasAnInverseAndNoneDenies() throws {
        for entity in TasksSchema.schema.entities where TasksSchema.synced.contains(where: { Schema.entityName(for: $0) == entity.name }) {
            for relationship in entity.relationships {
                #expect(relationship.inverseKeyPath != nil || relationship.inverseName != nil, "\(entity.name).\(relationship.name)")
                #expect(relationship.deleteRule != .deny, "\(entity.name).\(relationship.name)")
                #expect(relationship.isOptional || !relationship.isToOneRelationship, "\(entity.name).\(relationship.name)")
            }
            for attribute in entity.attributes {
                #expect(!attribute.isUnique, "\(entity.name).\(attribute.name)")
            }
        }
    }
}
