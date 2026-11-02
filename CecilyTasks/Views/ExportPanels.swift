import SwiftUI
import TasksCore
import UniformTypeIdentifiers

/// The save panel for an export, the panel to choose an export to restore, and what came of
/// either.
private struct ExportPanels: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .fileExporter(isPresented: isExportingAll, document: folder, contentType: .folder, defaultFilename: folder?.url.lastPathComponent) { _ in
                model.exporting = nil
            }
            .fileExporter(isPresented: isExportingMarkdown, document: markdown, contentType: MarkdownFile.type, defaultFilename: markdown?.name) {
                _ in
                model.exporting = nil
            }
            .fileImporter(isPresented: $model.isChoosingRestore, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result { model.restore(from: folder) }
            }
            .alert("Restored", isPresented: isShowingRestored) {
                Button("OK") { model.restored = nil }
            } message: {
                Text(model.restored == 1 ? "1 item is back." : "\(model.restored ?? 0) items are back.")
            }
            .alert("Couldn’t Do That", isPresented: isShowingProblem) {
                Button("OK") { model.exportProblem = nil }
            } message: {
                Text(model.exportProblem ?? "")
            }
    }

    private var folder: ExportFolder? {
        if case .all(let url) = model.exporting { ExportFolder(url: url) } else { nil }
    }

    private var markdown: MarkdownFile? {
        if case .markdown(let name, let text) = model.exporting { MarkdownFile(name: name, text: text) } else { nil }
    }

    private var isExportingAll: Binding<Bool> {
        Binding(get: { folder != nil }, set: { if !$0, folder != nil { model.exporting = nil } })
    }

    private var isExportingMarkdown: Binding<Bool> {
        Binding(get: { markdown != nil }, set: { if !$0, markdown != nil { model.exporting = nil } })
    }

    private var isShowingRestored: Binding<Bool> {
        Binding(get: { model.restored != nil }, set: { if !$0 { model.restored = nil } })
    }

    private var isShowingProblem: Binding<Bool> {
        Binding(get: { model.exportProblem != nil }, set: { if !$0 { model.exportProblem = nil } })
    }
}

extension View {
    func exportPanels() -> some View {
        modifier(ExportPanels())
    }
}

/// A full export's folder, as written to the temporary folder, for the save panel.
nonisolated struct ExportFolder: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url)
    }
}

/// A Markdown file, for the save panel.
nonisolated struct MarkdownFile: FileDocument {
    static let type = UTType("net.daringfireball.markdown") ?? .plainText
    static let readableContentTypes: [UTType] = [type]
    let name: String
    let text: String

    init(name: String, text: String) {
        self.name = name.isEmpty ? "Untitled" : name
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        name = configuration.file.filename ?? "Untitled"
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
