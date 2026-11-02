import CloudKit
import Foundation
import Testing

@testable import TasksCore

@MainActor
struct CloudKitSchemaTests {
    let schema = CloudKitSchema(
        zoneID: CKRecordZone.ID(zoneName: TasksSync.zoneName, ownerName: CKCurrentUserDefaultName), references: SyncModels.references,
        assets: SyncModels.assets, fields: SyncModels.fieldNames)
    let folder = FileManager.default.temporaryDirectory

    @Test func anItemsFieldsAreEncryptedAndItsReferencesArent() throws {
        let id = RecordID(type: "Item", name: UUID().uuidString)
        let parent = UUID().uuidString
        let contexts = [UUID().uuidString, UUID().uuidString]
        let record = ServerRecord(
            id: id, tag: nil,
            fields: [
                "title": .string("Email Sam"), "body": .string("**soon**"), "parent": .string(parent), "contexts": .strings(contexts),
                "sortOrder": .double(2.5), "dueDate": .date(LocalDate(2026, 11, 6).storedDate),
            ])
        let ck = try schema.ckRecord(record, assetFolder: folder)
        #expect(ck.recordType == "Item" && ck.recordID.recordName == "Item_\(id.name)")
        #expect(ck.encryptedValues["title"] as? String == "Email Sam")
        #expect(ck["title"] == nil)
        #expect((ck["parent"] as? CKRecord.Reference)?.recordID.recordName == "Item_\(parent)")
        #expect(ck.encryptedValues["contexts"] as? [String] == contexts)

        let back = try #require(schema.serverRecord(ck))
        #expect(back.id == id)
        for (field, value) in record.fields {
            #expect(back.fields[field] == value, "\(field)")
        }
        #expect(back.fields["waitingOn"] == .null, "a field not set reads as empty")
    }

    @Test func anAttachmentsFileIsAnAsset() throws {
        let id = RecordID(type: "Attachment", name: UUID().uuidString)
        let data = Data((0..<10_000).map { UInt8($0 % 256) })
        let ck = try schema.ckRecord(
            ServerRecord(id: id, tag: nil, fields: ["filename": .string("plan.pdf"), "data": .data(data)]), assetFolder: folder)
        let asset = try #require(ck["data"] as? CKAsset)
        #expect(try Data(contentsOf: #require(asset.fileURL)) == data)
        #expect(ck.encryptedValues["data"] == nil)
        #expect(try #require(schema.serverRecord(ck)).fields["data"] == .data(data))
    }

    @Test func aRecordSavedBeforeKeepsItsSystemFields() throws {
        let id = RecordID(type: "Project", name: UUID().uuidString)
        let first = try schema.ckRecord(ServerRecord(id: id, tag: nil, fields: ["title": .string("Garden")]), assetFolder: folder)
        let tag = CloudKitSchema.systemFields(of: first)
        let again = try schema.ckRecord(ServerRecord(id: id, tag: tag, fields: ["outcome": .string("Planted")]), assetFolder: folder)
        #expect(again.recordID == first.recordID)
        #expect(again.encryptedValues["outcome"] as? String == "Planted")
    }

    @Test func recordsThatArentTheAppsAreIgnored() {
        let share = CKRecord(recordType: "cloudkit.share", recordID: CKRecord.ID(recordName: "share", zoneID: schema.zoneID))
        #expect(schema.serverRecord(share) == nil)
        let unknown = CKRecord(recordType: "Thing", recordID: CKRecord.ID(recordName: "Thing_1", zoneID: schema.zoneID))
        #expect(schema.serverRecord(unknown) == nil)
    }

    @Test func noFieldStartsWithAnUnderscore() {
        for (type, fields) in SyncModels.fieldNames {
            #expect(fields.allSatisfy { !$0.hasPrefix("_") }, "\(type)")
        }
    }
}
