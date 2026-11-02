import Foundation

/// Where the person's store is kept: a folder in the App Group container, which the app and its
/// extensions share.
public enum StoreFolder {
    public static let appGroup = "group.com.ligertwood.cecily.tasks"
    /// The folder's name. A debug build, which syncs with iCloud's Development environment, keeps
    /// its store and sync's state apart from a release build's, which syncs with Production.
    #if DEBUG
        public static let name = "Cecily Tasks (Development)"
    #else
        public static let name = "Cecily Tasks"
    #endif
    public static let storeName = "Tasks.store"

    /// The folder in the App Group container, or nil when this build can't use the group.
    public static var shared: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: name, directoryHint: .isDirectory)
    }

    /// Copies everything in `earlier` into `folder` when `folder` has no store and `earlier` has
    /// one, leaving `earlier` as it is. The copy is made beside `folder` and moved into it with the
    /// store last, so a store in `folder` means everything else arrived too.
    public static func fill(_ folder: URL, from earlier: URL) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: folder.appending(path: storeName).path),
            files.fileExists(atPath: earlier.appending(path: storeName).path)
        else { return }
        let copy = folder.deletingLastPathComponent().appending(path: ".\(folder.lastPathComponent) copy", directoryHint: .isDirectory)
        if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.copyItem(at: earlier, to: copy)
        let names = try files.contentsOfDirectory(atPath: copy.path)
        for name in names.filter({ $0 != storeName }) + [storeName] {
            let destination = folder.appending(path: name)
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.moveItem(at: copy.appending(path: name), to: destination)
        }
        try files.removeItem(at: copy)
    }
}
