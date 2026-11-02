import Foundation
import TasksCore
import UniformTypeIdentifiers

/// Reads what another app shared: a link, text, or a file, from the first item it gave.
enum ShareInput {
    static func read(_ items: [NSExtensionItem]) async throws -> SharedItem {
        let item = items.first
        var link: URL?
        var text: String?
        var file: SharedItem.File?
        for provider in item?.attachments ?? [] {
            if link == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            {
                link = await loadURL(provider)
            } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                text = await loadText(provider)
            } else if file == nil, let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) }) {
                file = try await loadFile(provider, as: type)
            }
        }
        return try SharedItem.read(
            link: link, pageTitle: item?.attributedTitle?.string, text: text ?? item?.attributedContentText?.string, file: file)
    }

    nonisolated private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    nonisolated private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    /// The file, read only when it's no bigger than `SharedItem.largestFile`.
    nonisolated private static func loadFile(_ provider: NSItemProvider, as type: UTType) async throws -> SharedItem.File {
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? SharedItem.Problem.nothing)
                    return
                }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= SharedItem.largestFile else { throw SharedItem.Problem.tooLarge }
                    let data = try Data(contentsOf: url)
                    continuation.resume(
                        returning: SharedItem.File(name: name(suggested, url: url, type: type), contentType: type.identifier, data: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The name the sharing app gave, with the type's extension, or the file's own name.
    nonisolated private static func name(_ suggested: String?, url: URL, type: UTType) -> String {
        guard let suggested, !suggested.isEmpty else { return url.lastPathComponent }
        guard let ext = type.preferredFilenameExtension, !suggested.lowercased().hasSuffix(".\(ext.lowercased())") else { return suggested }
        return "\(suggested).\(ext)"
    }
}
