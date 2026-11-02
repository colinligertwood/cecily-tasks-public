import QuickLook
import SwiftUI
import TasksCore
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#else
    import UIKit
    import VisionKit
#endif

/// An open item's attachments, in a row between its subtasks and its notes, only when it has
/// some: images as pictures, other files as their icon, name and size. Choosing one opens it in
/// Quick Look, with the item's others beside it. Under them is why files couldn't be added, when
/// they couldn't.
struct AttachmentsSection: View {
    let item: Item
    @Environment(AppModel.self) private var model
    @State private var preview: URL?
    @State private var previews: [URL] = []

    var body: some View {
        let attachments = item.attachmentsInOrder
        if !attachments.isEmpty || problem != nil {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: Spacing.small) {
                            ForEach(attachments) { attachment in
                                AttachmentTile(attachment: attachment) { open(attachment, among: attachments) }
                            }
                        }
                        .padding(.vertical, Spacing.hairline)
                    }
                    .scrollIndicators(.never)
                }
                if let problem {
                    Text(problem)
                        .font(.detail)
                        .foregroundStyle(.secondary)
                }
            }
            .quickLookPreview($preview, in: previews)
            .onDisappear {
                if model.attachmentProblem?.itemID == item.id { model.attachmentProblem = nil }
            }
        }
    }

    private var problem: String? {
        model.attachmentProblem?.itemID == item.id ? model.attachmentProblem?.message : nil
    }

    private func open(_ attachment: Attachment, among attachments: [Attachment]) {
        previews = attachments.compactMap(model.fileURL)
        preview = model.fileURL(for: attachment)
    }
}

/// One attachment: an image's picture, or a file's icon with its name and size; a button that
/// opens it, with a menu to open it in another app, save or share it, or delete it.
private struct AttachmentTile: View {
    let attachment: Attachment
    let open: () -> Void
    @Environment(AppModel.self) private var model
    @State private var picture: CGImage?

    static let height: CGFloat = 56

    var body: some View {
        Button(action: open) {
            if attachment.isImage, let picture {
                Image(decorative: picture, scale: 2)
                    .resizable()
                    .scaledToFill()
                    .frame(width: min(Self.height * 2, Self.height * aspect(picture)), height: Self.height)
                    .clipShape(.rect(cornerRadius: Spacing.small))
                    .overlay { RoundedRectangle(cornerRadius: Spacing.small).strokeBorder(.separator) }
            } else {
                chip
            }
        }
        .buttonStyle(.plain)
        .help(attachment.filename)
        .accessibilityLabel("\(attachment.filename), \(attachment.sizeText)")
        .contextMenu { menu }
        .task(id: attachment.id) { picture = await Self.picture(of: attachment) }
    }

    private var chip: some View {
        HStack(spacing: Spacing.small) {
            icon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.sizeText)
                    .font(.detail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.horizontal, Spacing.small)
        .frame(height: Self.height)
        .background(.fill.tertiary, in: .rect(cornerRadius: Spacing.small))
    }

    @ViewBuilder private var icon: some View {
        if let picture {
            Image(decorative: picture, scale: 2)
                .resizable()
                .scaledToFit()
        } else {
            #if os(macOS)
                Image(nsImage: NSWorkspace.shared.icon(for: attachment.type))
                    .resizable()
                    .scaledToFit()
            #else
                Image(systemName: Self.symbol(for: attachment.type))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            #endif
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Quick Look", systemImage: "eye", action: open)
        #if os(macOS)
            Menu("Open With") {
                ForEach(NSWorkspace.shared.urlsForApplications(toOpen: attachment.type), id: \.self) { app in
                    Button {
                        if let url = model.fileURL(for: attachment) {
                            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                        }
                    } label: {
                        Label {
                            Text(FileManager.default.displayName(atPath: app.path()).replacing(/\.app$/, with: ""))
                        } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path()))
                        }
                    }
                }
            }
            Button("Save As…", systemImage: "square.and.arrow.down", action: saveAs)
        #else
            if let url = model.fileURL(for: attachment) {
                ShareLink(item: url, preview: SharePreview(attachment.filename)) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }
        #endif
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete(attachment) }
    }

    #if os(macOS)
        private func saveAs() {
            guard let source = model.fileURL(for: attachment) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.filename
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let destination = panel.url else { return }
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: source, to: destination)
            }
        }
    #else
        /// A symbol for a file of `type`, where there's no picture of it.
        static func symbol(for type: UTType) -> String {
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .audiovisualContent) { return type.conforms(to: .audio) ? "waveform" : "film" }
            if type.conforms(to: .archive) { return "archivebox" }
            if type.conforms(to: .spreadsheet) { return "tablecells" }
            if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
            if type.conforms(to: .text) { return "doc.text" }
            return "doc"
        }
    #endif

    private func aspect(_ image: CGImage) -> CGFloat {
        image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 1
    }

    /// Its thumbnail, or for an image without one, the image made smaller.
    private static func picture(of attachment: Attachment) async -> CGImage? {
        let pixels = Int(Thumbnail.size) * 2
        if let thumbnail = attachment.thumbnail {
            return await Task.detached { Thumbnail.image(from: thumbnail, pixels: pixels) }.value
        }
        guard attachment.isImage, let data = attachment.data else { return nil }
        return await Task.detached { Thumbnail.image(from: data, pixels: pixels) }.value
    }
}

/// The ways to add an attachment to an item, in its menus: Add Attachment… and, on iPhone and
/// iPad, Take Photo and Scan Document where there's a camera.
struct AttachmentMenuItems: View {
    let item: Item
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Add Attachment…", systemImage: "paperclip") { model.attachingTo = item }
        #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { model.photographing = item }
            }
            if VNDocumentCameraViewController.isSupported {
                Button("Scan Document", systemImage: "doc.viewfinder") { model.scanning = item }
            }
        #endif
    }
}

/// Takes files dropped onto an item as its attachments, saying while they're over it.
private struct AttachmentDrop: DropDelegate {
    let item: Item
    let model: AppModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        item.bucket != .trash && AppModel.canAttach(info.itemProviders(for: [.item]))
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.item]).filter { AppModel.attachableType($0) != nil }
        guard !providers.isEmpty else { return false }
        model.attach(providers, to: item)
        return true
    }
}

/// The panels for adding attachments: choosing files, and on iPhone and iPad, the camera and the
/// document scanner; and why files couldn't be added when no open item says it. On iPhone the
/// open item, in its sheet, has its own, `inOpenItem`.
private struct AttachmentPanels: ViewModifier {
    let inOpenItem: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: isPresenting(\.attachingTo), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard let item = model.attachingTo, case .success(let urls) = result else { return }
                Task { await model.attach(urls, to: item) }
            }
            .alert("Couldn’t Add That", isPresented: isShowingProblem) {
                Button("OK") { model.attachmentProblem = nil }
            } message: {
                Text(model.attachmentProblem?.message ?? "")
            }
            #if os(iOS)
                .fullScreenCover(isPresented: isPresenting(\.photographing)) {
                    if let item = model.photographing {
                        CameraView { data in
                            model.attach(data, named: "Photo \(Self.stamp).jpeg", to: item)
                        } done: {
                            model.photographing = nil
                        }
                        .ignoresSafeArea()
                    }
                }
                .fullScreenCover(isPresented: isPresenting(\.scanning)) {
                    if let item = model.scanning {
                        ScannerView { data in
                            model.attach(data, named: "Scan \(Self.stamp).pdf", to: item)
                        } done: {
                            model.scanning = nil
                        }
                        .ignoresSafeArea()
                    }
                }
            #endif
    }

    /// Whether these panels are the ones to show: on iPhone, the open item's while it's open.
    private var isActive: Bool {
        #if os(iOS)
            inOpenItem == (model.openItem != nil)
        #else
            true
        #endif
    }

    private func isPresenting(_ request: ReferenceWritableKeyPath<AppModel, Item?>) -> Binding<Bool> {
        Binding(
            get: { isActive && model[keyPath: request] != nil },
            set: { if !$0, isActive { model[keyPath: request] = nil } })
    }

    private var isShowingProblem: Binding<Bool> {
        Binding(
            get: { isActive && model.attachmentProblem != nil && model.attachmentProblem?.itemID != model.openItem },
            set: { if !$0, isActive { model.attachmentProblem = nil } })
    }

    /// The day and time, for a photo's or scan's name.
    private static var stamp: String {
        Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) + " at "
            + Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacing(":", with: ".")
    }
}

extension View {
    /// Takes files dropped onto the view as `item`'s attachments; `isTargeted` says while they're
    /// over it.
    func attachmentDrops(onto item: Item, model: AppModel, isTargeted: Binding<Bool>) -> some View {
        onDrop(of: [.item], delegate: AttachmentDrop(item: item, model: model, isTargeted: isTargeted))
    }

    /// The panels for adding attachments; `inOpenItem` for the ones in an open item's sheet.
    func attachmentPanels(inOpenItem: Bool = false) -> some View {
        modifier(AttachmentPanels(inOpenItem: inOpenItem))
    }
}

#if os(iOS)
    /// The camera, taking one photo, as JPEG.
    private struct CameraView: UIViewControllerRepresentable {
        let took: (Data) -> Void
        let done: () -> Void

        func makeUIViewController(context: UIViewControllerRepresentableContext<Self>) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ picker: UIImagePickerController, context: UIViewControllerRepresentableContext<Self>) {}

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let camera: CameraView

            init(_ camera: CameraView) {
                self.camera = camera
            }

            func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any])
            {
                if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) { camera.took(data) }
                camera.done()
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                camera.done()
            }
        }
    }

    /// The document scanner, its pages as one PDF.
    private struct ScannerView: UIViewControllerRepresentable {
        let scanned: (Data) -> Void
        let done: () -> Void

        func makeUIViewController(context: UIViewControllerRepresentableContext<Self>) -> VNDocumentCameraViewController {
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = context.coordinator
            return scanner
        }

        func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: UIViewControllerRepresentableContext<Self>) {}

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
            let scanner: ScannerView

            init(_ scanner: ScannerView) {
                self.scanner = scanner
            }

            func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
                if scan.pageCount > 0 { scanner.scanned(Self.pdf(of: scan)) }
                scanner.done()
            }

            func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
                scanner.done()
            }

            func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
                scanner.done()
            }

            /// The pages, each the size of its image.
            private static func pdf(of scan: VNDocumentCameraScan) -> Data {
                let pages = (0..<scan.pageCount).map(scan.imageOfPage)
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pages.first?.size ?? .zero))
                return renderer.pdfData { context in
                    for page in pages {
                        context.beginPage(withBounds: CGRect(origin: .zero, size: page.size), pageInfo: [:])
                        page.draw(in: CGRect(origin: .zero, size: page.size))
                    }
                }
            }
        }
    }
#endif
