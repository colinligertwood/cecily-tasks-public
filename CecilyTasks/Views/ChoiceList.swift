import SwiftUI

/// A short list to choose from, in a popover, each choice ticked while it applies: a click, or ↑ ↓
/// and Return, chooses one. It closes after a choice, or with `keepsOpen` stays, for ticking
/// several.
struct ChoiceList: View {
    struct Choice: Identifiable {
        let id: String
        let name: String
        let isOn: Bool
        let choose: () -> Void
    }

    let choices: [Choice]
    var keepsOpen = false
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        List(choices, selection: $selection) { choice in
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(choice.isOn ? 1 : 0)
                    .accessibilityHidden(true)
                Text(choice.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { pick(choice) }
            .accessibilityAddTraits(choice.isOn ? .isSelected : [])
        }
        .contextMenu(forSelectionType: String.self, menu: { _ in }) { ids in
            if let id = ids.first, let choice = choices.first(where: { $0.id == id }) { pick(choice) }
        }
        .focused($isFocused)
        .onAppear {
            selection = choices.first(where: \.isOn)?.id ?? choices.first?.id
            isFocused = true
        }
        .frame(width: 240, height: min(CGFloat(choices.count) * 28 + 16, 340))
    }

    private func pick(_ choice: Choice) {
        selection = choice.id
        choice.choose()
        if !keepsOpen { dismiss() }
    }
}
