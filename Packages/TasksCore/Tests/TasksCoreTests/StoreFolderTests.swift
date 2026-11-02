import Foundation
import Testing

@testable import TasksCore

struct StoreFolderTests {
    let root: URL
    let earlier: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        earlier = root.appending(path: "Application Support/Cecily Tasks", directoryHint: .isDirectory)
        folder = root.appending(path: "Group/Cecily Tasks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func names(in url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    private func fillEarlier() throws {
        try write("store", to: earlier.appending(path: "Tasks.store"))
        try write("wal", to: earlier.appending(path: "Tasks.store-wal"))
        try write("engine", to: earlier.appending(path: "CloudKitEngine.json"))
        try write("log", to: earlier.appending(path: "Logs/sync.log"))
    }

    @Test func everythingIsCopiedAndTheEarlierFolderKept() throws {
        try fillEarlier()
        try StoreFolder.fill(folder, from: earlier)
        #expect(try names(in: folder) == ["Tasks.store", "Tasks.store-wal", "CloudKitEngine.json", "Logs"])
        #expect(try read(folder.appending(path: "Tasks.store")) == "store")
        #expect(try read(folder.appending(path: "Logs/sync.log")) == "log")
        #expect(try names(in: earlier) == ["Tasks.store", "Tasks.store-wal", "CloudKitEngine.json", "Logs"])
        #expect(try names(in: folder.deletingLastPathComponent()) == ["Cecily Tasks"])
    }

    @Test func aFolderWithAStoreIsLeftAlone() throws {
        try fillEarlier()
        try write("newer", to: folder.appending(path: "Tasks.store"))
        try StoreFolder.fill(folder, from: earlier)
        #expect(try names(in: folder) == ["Tasks.store"])
        #expect(try read(folder.appending(path: "Tasks.store")) == "newer")
    }

    @Test func nothingIsMadeWithoutAnEarlierStore() throws {
        try write("engine", to: earlier.appending(path: "CloudKitEngine.json"))
        try StoreFolder.fill(folder, from: earlier)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try StoreFolder.fill(folder, from: root.appending(path: "Missing", directoryHint: .isDirectory))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func whatAnUnfinishedCopyLeftIsReplaced() throws {
        try fillEarlier()
        try write("partial", to: folder.appending(path: "Tasks.store-wal"))
        try write("partial", to: folder.deletingLastPathComponent().appending(path: ".Cecily Tasks copy/Tasks.store"))
        try StoreFolder.fill(folder, from: earlier)
        #expect(try read(folder.appending(path: "Tasks.store-wal")) == "wal")
        #expect(try read(folder.appending(path: "Tasks.store")) == "store")
        #expect(try names(in: folder.deletingLastPathComponent()) == ["Cecily Tasks"])
    }
}
