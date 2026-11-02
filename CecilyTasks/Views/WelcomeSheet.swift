import CecilyKit
import SwiftUI

/// First run's welcome: the brand's header, what the app is for, and the brain dump offered.
struct WelcomeSheet: View {
    /// Called when Start Brain Dump is chosen, before the sheet closes.
    let startBrainDump: () -> Void
    @Environment(\.dismiss) private var dismiss

    #if DEBUG
        /// `-ShowWelcome` shows it at launch, whether or not it's been seen.
        static var isForced: Bool { ProcessInfo.processInfo.arguments.contains("-ShowWelcome") }
    #else
        static let isForced = false
    #endif

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                BrandHeader(.tasks)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Welcome to Cecily Tasks")
                    .padding(.bottom, 8)
                Text("Everything you need to do, in one place, so you can choose what to do next.")
                Text("A few prompts to help you get everything on your mind into the Inbox. You can do it any time from the Inbox.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Brain Dump") {
                        startBrainDump()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(width: 480)
        #else
            .presentationDetents([.medium])
        #endif
    }
}
