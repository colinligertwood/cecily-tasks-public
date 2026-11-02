import SwiftUI
import TasksCore

/// The Share Sheet's view: what was shared, with its title to change, to add to the Inbox.
struct ShareView: View {
    let items: [NSExtensionItem]
    /// Closes the sheet; true when the item was added.
    let finish: (Bool) -> Void

    @State private var shared: SharedItem?
    @State private var title = ""
    @State private var problem: String?

    var body: some View {
        #if os(macOS)
            VStack(spacing: 0) {
                Text("Add to Inbox")
                    .font(.headline)
                    .padding(.top)
                form
                HStack {
                    Spacer()
                    Button("Cancel") { finish(false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Add to Inbox", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdd)
                }
                .padding([.horizontal, .bottom])
            }
            .frame(width: 440)
            .task { await read() }
        #else
            NavigationStack {
                form
                    .navigationTitle("Add to Inbox")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { finish(false) }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add to Inbox", action: add)
                                .disabled(!canAdd)
                        }
                    }
            }
            .task { await read() }
        #endif
    }

    private var form: some View {
        Form {
            if let shared {
                TextField("Title", text: $title)
                if let link = shared.link {
                    Label(link.absoluteString, systemImage: "link")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                if let file = shared.file {
                    Label(file.name, systemImage: "paperclip")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            } else if problem == nil {
                ProgressView()
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var canAdd: Bool {
        shared != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func read() async {
        do {
            let read = try await ShareInput.read(items)
            shared = read
            title = read.title
        } catch {
            problem = Self.words(for: error)
        }
    }

    private func add() {
        guard var shared else { return }
        shared.title = title.trimmingCharacters(in: .whitespaces)
        do {
            try ShareStore.add(shared)
            finish(true)
        } catch {
            problem = Self.words(for: error)
        }
    }

    static func words(for error: Error) -> String {
        switch error {
        case SharedItem.Problem.tooLarge: "Files over 50 MB can't be added."
        case SharedItem.Problem.nothing: "There's nothing here that can be added."
        case ShareStore.Problem.noStore: "Open Cecily Tasks once, then share this again."
        default: "Couldn't add this. \(error.localizedDescription)"
        }
    }
}
