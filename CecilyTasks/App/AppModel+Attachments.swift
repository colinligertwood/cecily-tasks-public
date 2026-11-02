import Foundation
import SwiftData
import TasksCore
import UniformTypeIdentifiers

/// Why files couldn't be added to an item.
struct AttachmentProblem: Equatable {
    let itemID: UUID
    let message: String
}

extension AppModel {
    /// Where attachments' files are written for Quick Look, other apps and sharing.
    static let attachmentFiles = FileManager.default.temporaryDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
    /// Where files being added are copied while they're read.
    nonisolated static let incomingFiles = FileManager.default.temporaryDirectory.appending(path: "Incoming", directoryHint: .isDirectory)

    /// The attachment's file, written where Quick Look and other apps can open it.
    func fileURL(for attachment: Attachment) -> URL? {
        try? attachment.writeFile(in: Self.attachmentFiles)
    }

    /// Adds the files at `urls` to `item`, each with its thumbnail, as one step that can be undone.
    /// A file that can't be added is left out, and why is said. Copies in `incomingFiles` are
    /// deleted once they're read.
    func attach(_ urls: [URL], to item: Item, problems: [String] = []) async {
        var files: [AttachedFile] = []
        var problems = problems
        for url in urls {
            let isScoped = url.startAccessingSecurityScopedResource()
            do {
                var file = try AttachedFile.read(url)
                file.thumbnail = await Thumbnail.make(for: url)
                files.append(file)
            } catch {
                problems.append(AttachedFile.message(for: error))
            }
            if isScoped { url.stopAccessingSecurityScopedResource() }
            if url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == Self.incomingFiles.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        attachmentProblem = problems.isEmpty ? nil : AttachmentProblem(itemID: item.id, message: problems.joined(separator: " "))
        guard !files.isEmpty, item.modelContext != nil, !item.isDeleted else { return }
        let added = files.map { item.attach($0) }
        save()
        registerRemoving(added, named: added.count == 1 ? "Add Attachment" : "Add Attachments")
    }

    /// Adds what was dropped or pasted onto `item`: files, and pictures and documents from other
    /// apps.
    func attach(_ providers: [NSItemProvider], to item: Item) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.incomingFile(provider) { urls.append(url) }
            }
            await attach(urls, to: item)
        }
    }

    /// Adds `data` to `item` as a file named `name`, such as a photo just taken or a page scanned.
    @discardableResult
    func attach(_ data: Data, named name: String, to item: Item) -> Task<Void, Never> {
        attach([PastedFile(name: name, data: data)], to: item)
    }

    /// Adds files pasted or dropped into the notes to `item`; one without its contents was too big.
    @discardableResult
    func attach(_ files: [PastedFile], to item: Item) -> Task<Void, Never> {
        var urls: [URL] = []
        var problems: [String] = []
        for file in files {
            guard let data = file.data else {
                problems.append(AttachedFile.message(for: AttachedFile.Problem.tooLarge(file.name)))
                continue
            }
            do {
                let url = Self.incomingFiles.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                    .appending(path: FullExport.safeFilename(file.name))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                urls.append(url)
            } catch {
                problems.append(AttachedFile.message(for: error))
            }
        }
        return Task { await attach(urls, to: item, problems: problems) }
    }

    /// Deletes the attachment, as a step that can be undone.
    func delete(_ attachment: Attachment) {
        remove([attachment], named: "Delete Attachment")
    }

    private func remove(_ attachments: [Attachment], named name: String) {
        let kept = attachments.compactMap(\.kept)
        attachments.forEach(context.delete)
        save()
        undoManager?.registerUndo(withTarget: self) { model in model.putBack(kept, named: name) }
        undoManager?.setActionName(name)
    }

    private func putBack(_ kept: [Attachment.Kept], named name: String) {
        let back = kept.compactMap { $0.putBack(in: context) }
        save()
        registerRemoving(back, named: name)
    }

    private func registerRemoving(_ attachments: [Attachment], named name: String) {
        undoManager?.registerUndo(withTarget: self) { model in model.remove(attachments, named: name) }
        undoManager?.setActionName(name)
    }

    /// Whether what's being dragged has something that can be added as an attachment: a file, or
    /// a picture or document, but not the app's own rows or text.
    nonisolated static func canAttach(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { attachableType($0) != nil }
    }

    /// The type to read from `provider` to add it as a file: a file's location, or else the first
    /// of its types that's a file's contents. Text counts only when it comes with a file's name.
    nonisolated static func attachableType(_ provider: NSItemProvider) -> UTType? {
        let types = provider.registeredContentTypes
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .fileURL }
        return types.first { type in
            type.conforms(to: .data) && !type.conforms(to: .url) && (!type.conforms(to: .text) || provider.suggestedName != nil)
        }
    }

    /// A copy of what `provider` holds, as a file in `incomingFiles`; nil when it can't be read.
    nonisolated private static func incomingFile(_ provider: NSItemProvider) async -> URL? {
        guard let type = attachableType(provider) else { return nil }
        if type == .fileURL {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            guard let url else { return nil }
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            return try? copy(url, named: url.lastPathComponent)
        }
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                continuation.resume(returning: url.flatMap { try? copy($0, named: name(suggested, url: $0, type: type)) })
            }
        }
    }

    /// Copies the file at `url` into a folder of its own in `incomingFiles`, as `name`.
    nonisolated private static func copy(_ url: URL, named name: String) throws -> URL {
        let copy = incomingFiles.appending(path: UUID().uuidString, directoryHint: .isDirectory).appending(path: name)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// The name the other app gave, with the type's extension, or else the file's own name.
    nonisolated private static func name(_ suggested: String?, url: URL, type: UTType) -> String {
        guard let suggested, !suggested.isEmpty else { return url.lastPathComponent }
        guard let ext = type.preferredFilenameExtension, !suggested.lowercased().hasSuffix(".\(ext.lowercased())") else { return suggested }
        return "\(suggested).\(ext)"
    }
}
