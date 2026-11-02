import SwiftUI

#if os(macOS)
    import AppKit

    /// A whole number typed in a small field, right-aligned. Clicking it selects the number, to type
    /// over. A number in `range` takes effect as it's typed; on Return or leaving the field, what's
    /// there is kept within `range`, or put back when it isn't a number.
    struct NumberField: NSViewRepresentable {
        @Binding var value: Int
        let range: ClosedRange<Int>

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> SelectingTextField {
            let field = SelectingTextField()
            field.alignment = .right
            field.bezelStyle = .roundedBezel
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.delegate = context.coordinator
            field.target = context.coordinator
            field.action = #selector(Coordinator.commit(_:))
            field.integerValue = value
            return field
        }

        func updateNSView(_ field: SelectingTextField, context: Context) {
            context.coordinator.parent = self
            field.isEnabled = context.environment.isEnabled
            if field.currentEditor() == nil, field.integerValue != value { field.integerValue = value }
        }

        final class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: NumberField

            init(_ parent: NumberField) {
                self.parent = parent
            }

            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSTextField, let typed = Int(field.stringValue), parent.range.contains(typed) else {
                    return
                }
                parent.value = typed
            }

            func controlTextDidEndEditing(_ notification: Notification) {
                guard let field = notification.object as? NSTextField else { return }
                commit(field)
            }

            @objc func commit(_ sender: NSTextField) {
                let typed = Int(sender.stringValue.trimmingCharacters(in: .whitespaces)) ?? parent.value
                let kept = min(max(typed, parent.range.lowerBound), parent.range.upperBound)
                if parent.value != kept { parent.value = kept }
                sender.integerValue = kept
            }
        }
    }

    /// A text field whose text is all selected when a click puts the cursor in it.
    final class SelectingTextField: NSTextField {
        override func mouseDown(with event: NSEvent) {
            let wasEditing = currentEditor() != nil
            super.mouseDown(with: event)
            if !wasEditing { currentEditor()?.selectAll(nil) }
        }
    }
#else
    /// A whole number typed in a small field, right-aligned, with the number pad. Its number is
    /// selected when it gets the cursor, to type over. A number in `range` takes effect as it's
    /// typed; leaving the field keeps it within `range`, or puts it back when it isn't a number.
    struct NumberField: View {
        @Binding var value: Int
        let range: ClosedRange<Int>
        @State private var text = ""
        @State private var selection: TextSelection?
        @FocusState private var isFocused: Bool

        var body: some View {
            TextField("", text: $text, selection: $selection)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onAppear { text = "\(value)" }
                .onChange(of: isFocused) { _, focused in
                    if focused {
                        Task { selection = TextSelection(range: text.startIndex..<text.endIndex) }
                    } else {
                        commit()
                    }
                }
                .onChange(of: text) { _, typed in
                    if let number = Int(typed), range.contains(number) { value = number }
                }
                .onChange(of: value) { _, number in
                    if !isFocused { text = "\(number)" }
                }
        }

        private func commit() {
            let typed = Int(text.trimmingCharacters(in: .whitespaces)) ?? value
            value = min(max(typed, range.lowerBound), range.upperBound)
            text = "\(value)"
        }
    }
#endif
