#if DEBUG
    import CloudKit
    import Foundation
    import TasksCore

    /// Debug builds only: `-tasks-cloudkit-schema` puts every record type and field Cecily Tasks syncs
    /// into the Development environment's schema, ready to deploy to Production in CloudKit Console.
    /// It saves one record of each type, with every field filled (`SyncModels.sampleRecords`), in a
    /// throwaway zone of the private database, then deletes the zone: the records go, their types
    /// and fields stay. Prints what it saved and quits.
    @MainActor
    enum DebugCloudKitSchema {
        static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-tasks-cloudkit-schema") }

        private static let container = CKContainer(identifier: CloudSync.containerID)
        private static var db: CKDatabase { container.privateCloudDatabase }

        static func run() async {
            setvbuf(stdout, nil, _IOLBF, 0)
            print("== CloudKit schema")
            let zone = CKRecordZone.ID(zoneName: "tasks-schema-\(UUID().uuidString.prefix(8))", ownerName: CKCurrentUserDefaultName)
            let folder = FileManager.default.temporaryDirectory.appending(path: zone.zoneName)
            let records: [CKRecord]
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let schema = CloudKitSchema(
                    zoneID: zone, references: SyncModels.references, assets: SyncModels.assets, fields: SyncModels.fieldNames)
                records = try SyncModels.sampleRecords().map { try schema.ckRecord($0, assetFolder: folder) }
            } catch {
                print("CKSCHEMA ✘ couldn't make the records: \(error); nothing saved")
                return
            }
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                let status = try await container.accountStatus()
                guard status == .available else {
                    print("CKSCHEMA ✘ iCloud account isn't available (status \(status.rawValue)); nothing saved")
                    return
                }
                _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
                print("CKSCHEMA ✔ made zone \(zone.zoneName)")
                let results = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
                for record in records {
                    switch results.saveResults[record.recordID] {
                    case .success:
                        let fields = Set(record.allKeys()).union(record.encryptedValues.allKeys()).sorted()
                        print("CKSCHEMA ✔ \(record.recordType): \(fields.joined(separator: ", "))")
                    case .failure(let error):
                        print("CKSCHEMA ✘ \(record.recordType): \(error)")
                    case nil:
                        print("CKSCHEMA ✘ \(record.recordType): no result")
                    }
                }
            } catch {
                print("CKSCHEMA ✘ stopped: \(error)")
            }
            do {
                _ = try await db.modifyRecordZones(saving: [], deleting: [zone])
                print("CKSCHEMA ✔ deleted zone \(zone.zoneName)")
            } catch {
                print("CKSCHEMA ✘ couldn't delete zone \(zone.zoneName): \(error). Delete it in CloudKit Console.")
            }
            print("CKSCHEMA DONE")
        }
    }
#endif
