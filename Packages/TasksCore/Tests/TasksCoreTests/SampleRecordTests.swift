import CloudKit
import Foundation
import Testing

@testable import TasksCore

/// The records that write every record type and field into CloudKit's schema.
struct SampleRecordTests {
    @Test func oneRecordOfEachTypeWithEveryFieldFilled() {
        let records = SyncModels.sampleRecords()
        #expect(Set(records.map(\.id.type)) == Set(SyncModels.all.map { $0.recordType }))
        for record in records {
            #expect(Set(record.fields.keys) == Set(SyncModels.fieldNames[record.id.type] ?? []), "\(record.id.type)")
            for (field, value) in record.fields {
                #expect(value != .null, "\(record.id.type).\(field)")
            }
        }
    }

    @Test func theyMakeCloudKitRecordsWithEveryField() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SampleRecordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let schema = CloudKitSchema(
            zoneID: CKRecordZone.ID(zoneName: "schema", ownerName: CKCurrentUserDefaultName), references: SyncModels.references,
            assets: SyncModels.assets, fields: SyncModels.fieldNames)
        for record in SyncModels.sampleRecords() {
            let ck = try schema.ckRecord(record, assetFolder: folder)
            let set = Set(ck.allKeys()).union(ck.encryptedValues.allKeys())
            #expect(set == Set(record.fields.keys), "\(record.id.type)")
        }
    }
}
