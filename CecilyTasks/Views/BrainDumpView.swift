import SwiftData
import SwiftUI
import TasksCore

/// The guided brain dump: a prompt at a time, each line typed an Inbox item.
/// What's typed on a page goes to the Inbox when moving on from it, so leaving partway keeps it.
struct BrainDumpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query private var settings: [AppSettings]
    @State private var page = 0
    @State private var text = ""
    @State private var added = 0
    @FocusState private var focused: Bool

    private var prompts: [BrainDump.Prompt] {
        BrainDump.prompts(settings.first?.brainDumpPrompts ?? [])
    }

    var body: some View {
        NavigationStack {
            let prompts = prompts
            let prompt = prompts[min(page, prompts.count - 1)]
            VStack(alignment: .leading, spacing: 14) {
                Text(prompt.title).font(.title2.weight(.semibold))
                if !prompt.detail.isEmpty {
                    Text(prompt.detail).foregroundStyle(.secondary)
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
                    .frame(minHeight: 180)
                Text("One thing per line. Everything goes to your Inbox, to decide on later.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                HStack {
                    Text(added == 1 ? "1 item added" : "\(added) items added").foregroundStyle(.secondary)
                    Spacer()
                    if page < prompts.count - 1 {
                        Button("Next") { next() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button("Finish") {
                            keep()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(20)
            .navigationTitle("Brain Dump \(min(page, prompts.count - 1) + 1) of \(prompts.count)")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        keep()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(width: 520, height: 460)
        #endif
        .onAppear { focused = true }
    }

    private func keep() {
        added += model.capture(text)
        text = ""
    }

    private func next() {
        keep()
        page += 1
        focused = true
    }
}
