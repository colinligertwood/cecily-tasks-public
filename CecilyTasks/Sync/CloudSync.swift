import CloudKit
import Foundation
import OSLog
import Observation
import SwiftData
import TasksCore

extension Notification.Name {
    /// Posted before sync sends and fetches, so editors save what's typed first.
    static let willSync = Notification.Name("com.ligertwood.cecily.tasks.willSync")
    /// Posted when Return or Escape takes the cursor out of a field, so the list showing takes
    /// the keyboard back.
    static let doneTyping = Notification.Name("com.ligertwood.cecily.tasks.doneTyping")
}

/// Syncs the store with the person's private iCloud database, in one zone, through
/// `CloudKitSyncEngine` and `TasksSync`. Off until it's turned on, so a build without the iCloud
/// entitlement (an unsigned one, or the tests) never touches CloudKit.
@MainActor
@Observable
final class CloudSync {
    static let containerID = "iCloud.com.ligertwood.cecily.tasks"
    private static let onKey = "tasks-sync-on"
    /// Set once sync has been turned on or off, by the app or by the person: until then, a launch
    /// signed in to iCloud turns it on.
    private static let decidedKey = "tasks-sync-decided"

    private(set) var isOn = false
    private(set) var isWorking = false
    private(set) var isSyncing = false
    /// The iCloud account, in words: "Signed in", "Signed out" and so on.
    private(set) var account: String?
    /// Why sync isn't working, in plain words, if it isn't.
    private(set) var problem: String?
    /// Something to tell the person, once.
    var message: String?
    /// Edits made here that didn't reach iCloud before what they changed was deleted elsewhere.
    private(set) var lostEdits: [String] = []
    private(set) var lastSent: Date?
    private(set) var lastFetched: Date?
    /// What the last Sync Now did, in words.
    private(set) var lastResult: String?
    private(set) var pendingCount = 0
    /// Goes up whenever sync changes records, so views can read them afresh.
    private(set) var revision = 0

    @ObservationIgnored let container: ModelContainer
    /// False for a store that must never sync, such as a preview's.
    @ObservationIgnored let canSync: Bool
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var engine: CloudKitSyncEngine?
    @ObservationIgnored private var sync: TasksSync?
    /// Counts for the Sync Now under way.
    @ObservationIgnored private var sentThisRound = 0
    @ObservationIgnored private var receivedThisRound = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.ligertwood.cecily.tasks", category: "sync")

    /// `folder` keeps the engine's state.
    init(container: ModelContainer, folder: URL, canSync: Bool = true) {
        self.container = container
        self.folder = folder
        self.canSync = canSync
    }

    private var isAllowed: Bool { canSync && Self.canUseICloud }

    /// Where sync's settings are kept: apart for a debug build, which has a store of its own
    /// (`StoreFolder.name`).
    private static var defaults: UserDefaults {
        #if DEBUG
            UserDefaults(suiteName: "development") ?? .standard
        #else
            .standard
        #endif
    }

    private var engineStateURL: URL { folder.appending(path: "CloudKitEngine.json") }

    private static let zoneID = CKRecordZone.ID(zoneName: TasksSync.zoneName, ownerName: CKCurrentUserDefaultName)

    private static var schema: CloudKitSchema {
        CloudKitSchema(zoneID: zoneID, references: SyncModels.references, assets: SyncModels.assets, fields: SyncModels.fieldNames)
    }

    // MARK: - Turning on and off

    /// At launch: carries on syncing if it was on, or turns it on the first time, when this device
    /// is signed in to iCloud. Never in a build that can't use iCloud.
    func start() {
        guard isAllowed else {
            log.notice("This build can't use iCloud, so sync stays off")
            return
        }
        if Self.defaults.bool(forKey: Self.onKey), TasksSync.isSyncing(container) {
            log.notice("Sync was on: starting")
            attach(firstTime: false)
            syncNow()
        } else if Self.defaults.object(forKey: Self.decidedKey) == nil {
            log.notice("First launch: turning sync on if signed in to iCloud")
            Task { await turnOn(quietly: true) }
        } else {
            log.notice("Sync is off")
        }
    }

    /// Whether this build has the iCloud entitlement: a build from Xcode with signing does, an
    /// unsigned one or the tests' doesn't.
    static var canUseICloud: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) != nil
        #else
            return true
        #endif
    }

    /// Turns sync on. `quietly`, at a first launch, says nothing when this device isn't signed in.
    func turnOn(quietly: Bool = false) async {
        guard !isOn, isAllowed else { return }
        isWorking = true
        defer { isWorking = false }
        await checkAccount()
        guard account == "Signed in" else {
            if !quietly { problem = "Sign in to iCloud in Settings to sync." }
            return
        }
        do {
            try TasksSync.begin(container: container)
            try? FileManager.default.removeItem(at: engineStateURL)
            Self.defaults.set(true, forKey: Self.onKey)
            Self.defaults.set(true, forKey: Self.decidedKey)
            log.notice("Turning sync on")
            attach(firstTime: true)
            syncNow()
        } catch {
            log.error("Couldn't turn sync on: \(error.localizedDescription, privacy: .public)")
            problem = "Couldn't turn on iCloud sync. \(error.localizedDescription)"
        }
    }

    /// Stops syncing. Everything stays on this device, and in iCloud.
    func turnOff() {
        log.notice("Turning sync off")
        try? TasksSync.stop(container: container)
        try? FileManager.default.removeItem(at: engineStateURL)
        Self.defaults.set(false, forKey: Self.onKey)
        Self.defaults.set(true, forKey: Self.decidedKey)
        engine = nil
        sync = nil
        isOn = false
        pendingCount = 0
    }

    /// Stops syncing this store for now, when the app switches to another, leaving sync's
    /// settings as they are.
    func suspend() {
        guard isOn else { return }
        log.notice("Pausing sync")
        engine = nil
        sync = nil
        isOn = false
    }

    /// Asks iCloud whether this device is signed in.
    func checkAccount() async {
        guard canSync else {
            account = "Not used with this store"
            return
        }
        guard Self.canUseICloud else {
            account = "Not available in this build"
            return
        }
        do {
            let status = try await CKContainer(identifier: Self.containerID).accountStatus()
            account =
                switch status {
                case .available: "Signed in"
                case .noAccount: "Signed out"
                case .restricted: "Restricted on this device"
                case .temporarilyUnavailable: "Temporarily unavailable"
                case .couldNotDetermine: "Couldn't tell"
                @unknown default: "Unknown"
                }
            log.notice("iCloud account: \(self.account ?? "", privacy: .public)")
        } catch {
            account = "Couldn't tell"
            log.error("Couldn't check the iCloud account: \(error.localizedDescription, privacy: .public)")
            problem = Self.words(for: error)
        }
    }

    private func attach(firstTime: Bool) {
        let engine = CloudKitSyncEngine(
            database: CKContainer(identifier: Self.containerID).privateCloudDatabase, state: try? Data(contentsOf: engineStateURL))
        engine.stateDidChange = { [weak self] data in
            guard let self else { return }
            try? data.write(to: engineStateURL, options: .atomic)
        }
        engine.notice = { [weak self] notice in self?.handle(notice) }
        do {
            let sync = try TasksSync(container: container, engine: engine)
            connect(sync)
            engine.attach(sync, schema: Self.schema, binding: sync.binding)
            if firstTime {
                engine.createZone(Self.zoneID)
                sync.recordEverything()
            }
            sync.resume()
            self.engine = engine
            self.sync = sync
            isOn = true
            pendingCount = sync.pendingCount
            log.notice("Sync started, \(sync.pendingCount) changes waiting to send")
        } catch {
            log.error("Couldn't start sync: \(error.localizedDescription, privacy: .public)")
            problem = "Couldn't start iCloud sync. \(error.localizedDescription)"
        }
    }

    private func connect(_ sync: TasksSync) {
        sync.objectsDidChange = { [weak self] in self?.revision += 1 }
        sync.didExchange = { [weak self] in self?.didExchange($0) }
        sync.editsLost = { [weak self] in self?.lostEdits += $0 }
        sync.problem = { [weak self] in self?.problem = $0 }
    }

    // MARK: - Syncing

    /// Saves what's being typed, then sends what's waiting and fetches what's new. The engine also
    /// does this by itself, on pushes and soon after changes.
    func syncNow() {
        NotificationCenter.default.post(name: .willSync, object: nil)
        guard let engine, !isSyncing else { return }
        sync?.captureLocalChanges()
        isSyncing = true
        sentThisRound = 0
        receivedThisRound = 0
        log.notice("Sync Now: \(self.sync?.pendingCount ?? 0) changes waiting to send")
        Task {
            defer { isSyncing = false }
            do {
                try await engine.sendChanges()
                try await engine.fetchChanges()
                problem = nil
                lastResult = "Sent \(Self.count(sentThisRound, "change")), received \(Self.count(receivedThisRound, "change"))."
                log.notice("Sync Now finished: sent \(self.sentThisRound), received \(self.receivedThisRound)")
            } catch {
                log.error("Sync Now failed: \(error.localizedDescription, privacy: .public)")
                problem = Self.words(for: error)
                lastResult = nil
            }
            pendingCount = sync?.pendingCount ?? 0
        }
    }

    /// Reads edits saved here, for the pending count. Sync reads them by itself too.
    func noteLocalChanges() {
        sync?.captureLocalChanges()
        pendingCount = sync?.pendingCount ?? 0
    }

    private func didExchange(_ exchange: TasksSync.Exchange) {
        switch exchange {
        case .sent(let saved, let deleted, let refused):
            lastSent = .now
            sentThisRound += saved + deleted
            if let first = refused.first { problem = "iCloud didn't accept some changes: \(first) They'll be tried again." }
        case .received(let changed, let deleted):
            receivedThisRound += changed + deleted
        case .fetched:
            lastFetched = .now
        }
        pendingCount = sync?.pendingCount ?? 0
    }

    func dismissLostEdits() {
        lostEdits = []
    }

    private func handle(_ notice: CloudKitSyncEngine.Notice) {
        switch notice {
        case .accountChanged(let change):
            log.notice("iCloud account changed")
            switch change {
            case .signOut, .switchAccounts:
                turnOff()
                message = "You signed out of iCloud or changed Apple Account, so sync stopped. Everything is still on this device."
            case .signIn:
                break
            @unknown default:
                break
            }
            Task { await checkAccount() }
        case .zoneNotFound:
            // Not made yet: changes wait in the engine until it is.
            log.notice("The Tasks zone isn't in iCloud yet: making it")
            engine?.createZone(Self.zoneID)
        case .zoneDeleted:
            // Deleted from iCloud (by resetting iCloud data, say): make it again and send everything.
            log.notice("The Tasks zone was deleted from iCloud: sending everything again")
            guard let engine else { return }
            engine.createZone(Self.zoneID)
            try? TasksSync.begin(container: container)
            if let fresh = try? TasksSync(container: container, engine: engine) {
                connect(fresh)
                engine.attach(fresh, schema: Self.schema, binding: fresh.binding)
                fresh.recordEverything()
                fresh.resume()
                sync = fresh
            }
        case .zonesChanged:
            break
        case .problem(let text):
            log.error("Sync problem: \(text, privacy: .public)")
            problem = text
        }
    }

    // MARK: - Words

    /// What went wrong, in plain words.
    static func words(for error: Error) -> String {
        guard let error = error as? CKError else { return "Something went wrong: \(error.localizedDescription)" }
        switch error.code {
        case .notAuthenticated: return "This device isn't signed in to iCloud."
        case .networkUnavailable, .networkFailure: return "No internet connection. Changes will go when you're back online."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return "iCloud is busy. Sync will try again shortly."
        case .quotaExceeded: return "Your iCloud storage is full."
        case .badContainer, .missingEntitlement, .permissionFailure:
            return "This build can't use iCloud. Build it from Xcode with signing turned on."
        case .accountTemporarilyUnavailable: return "iCloud isn't available on this device just now."
        default: return "iCloud said: \(error.localizedDescription)"
        }
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }
}
