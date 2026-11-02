import SwiftData
import SwiftUI
import TasksCore

/// A text field that keeps what's typed to itself until it's done: Return, focus leaving, the
/// field going away, or a sync starting saves it with `save`. A line break typed in a field that
/// grows down is taken as Return. Return also takes the cursor out of it, and Escape takes the
/// cursor out without saving, putting back what was there; either gives the list showing the
/// keyboard back (`.doneTyping`). `suggest` gives the texts to offer for what's been typed: on
/// the Mac in a list under the field, and elsewhere as buttons below it that save the one tapped.
/// Setting `focusRequest` to true puts the cursor in it, and sets it back.
struct DoneTypingField: View {
    let title: String
    let text: String
    let axis: Axis
    let suggest: (String) -> [String]
    let save: (String) -> Void
    var focusRequest: Binding<Bool>?
    @State private var draft: String?
    /// Escape was pressed: what the field gives back as it lets go of the cursor isn't kept.
    @State private var isCancelled = false
    @FocusState private var isFocused: Bool

    init(
        _ title: String, text: String, axis: Axis = .horizontal, suggest: @escaping (String) -> [String] = { _ in [] },
        focusRequest: Binding<Bool>? = nil, save: @escaping (String) -> Void
    ) {
        self.title = title
        self.text = text
        self.axis = axis
        self.suggest = suggest
        self.focusRequest = focusRequest
        self.save = save
    }

    var body: some View {
        let suggestions = isFocused ? draft.map(suggest) ?? [] : []
        #if os(macOS)
            field
                .textInputSuggestions(suggestions, id: \.self) { Text($0).textInputCompletion($0) }
        #else
            VStack(alignment: .trailing) {
                field
                if !suggestions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    draft = suggestion
                                    isFocused = false
                                    finish()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
        #endif
    }

    private var field: some View {
        TextField(
            title,
            text: Binding(
                get: { draft ?? text },
                set: { typed in
                    guard !isCancelled else { return }
                    if typed.contains("\n") {
                        draft = typed.replacing("\n", with: "")
                        isFocused = false
                        finish()
                    } else {
                        draft = typed
                    }
                }),
            axis: axis
        )
        .focused($isFocused)
        .onSubmit {
            isFocused = false
            finish()
            NotificationCenter.default.post(name: .doneTyping, object: nil)
        }
        .onKeyPress(.escape) {
            isCancelled = true
            draft = nil
            isFocused = false
            NotificationCenter.default.post(name: .doneTyping, object: nil)
            return .handled
        }
        .onChange(of: isFocused) { _, focused in
            if focused { isCancelled = false } else { finish() }
        }
        .onDisappear(perform: finish)
        .onChange(of: focusRequest?.wrappedValue ?? false, initial: true) { _, requested in
            guard requested else { return }
            isFocused = true
            focusRequest?.wrappedValue = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .willSync)) { _ in finish() }
    }

    private func finish() {
        guard let draft else { return }
        self.draft = nil
        save(draft)
    }
}
