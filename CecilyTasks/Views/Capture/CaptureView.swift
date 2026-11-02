import SwiftData
import SwiftUI
import TasksCore

/// Quick capture: type one or more lines, each an Inbox item. Shows what the tokens will fill in
/// before it's added.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool
    /// Called after adding, or on cancelling.
    var done: () -> Void = {}

    private var drafts: [CaptureDraft] {
        CaptureParser.parse(text, today: model.today, vocabulary: Capture.vocabulary(in: model.context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What's on your mind? One item per line.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
            let drafts = drafts
            if drafts.contains(where: \.hasDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(drafts.enumerated()), id: \.offset) { _, draft in
                        if draft.hasDetails {
                            Text(draft.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Add #project, @context, due:fri, !tomorrow, or every 2 weeks to fill those in.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Cancel", role: .cancel) {
                    text = ""
                    done()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(drafts.count > 1 ? "Add \(drafts.count) Items" : "Add to Inbox", action: add)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(drafts.isEmpty)
            }
        }
        .padding()
        .onAppear { focused = true }
    }

    private func add() {
        model.capture(text)
        text = ""
        done()
    }
}

extension CaptureDraft {
    var hasDetails: Bool {
        project != nil || !contexts.isEmpty || dueDate != nil || scheduledDate != nil || repeatRule != nil
    }

    /// "Call the builder: Kitchen refit · Calls · due 23 Oct · every 2 weeks".
    var summary: String {
        var parts: [String] = []
        if let project { parts.append(project) }
        parts += contexts
        if let dueDate { parts.append("due " + Self.format(dueDate)) }
        if let scheduledDate { parts.append("on " + Self.format(scheduledDate)) }
        if let repeatText { parts.append(repeatText.lowercased()) }
        return "\(title.isEmpty ? "Untitled" : title): " + parts.joined(separator: " · ")
    }

    static func format(_ day: LocalDate) -> String {
        day.date(in: .current, hour: 12).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// Quick capture in a sheet, from ⌘N or the + button.
struct CaptureSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CaptureView { dismiss() }
                .navigationTitle("Add to Inbox")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        #if os(macOS)
            .frame(width: Spacing.captureWidth)
        #endif
    }
}
