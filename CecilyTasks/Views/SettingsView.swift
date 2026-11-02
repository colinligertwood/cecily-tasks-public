import SwiftData
import SwiftUI
import TasksCore

/// Settings: iCloud sync, the quick-capture shortcut on the Mac and the brain dump's prompts, then
/// notifications, calendars, areas and contexts, as panes on the Mac and pages on iPhone.
struct SettingsView: View {
    #if os(macOS)
        @AppStorage(SettingsPane.key) private var pane = SettingsPane.general

        var body: some View {
            TabView(selection: $pane) {
                Tab("General", systemImage: "gear", value: SettingsPane.general) { GeneralSettings() }
                Tab("Notifications", systemImage: "bell", value: SettingsPane.notifications) { NotificationSettingsView() }
                Tab("Calendars", systemImage: "calendar", value: SettingsPane.calendars) { CalendarSettings() }
                Tab("Areas", systemImage: ItemField.area.symbol, value: SettingsPane.areas) { AreasSettings() }
                Tab("Contexts", systemImage: ItemField.contexts.symbol, value: SettingsPane.contexts) { ContextsSettings() }
            }
        }
    #else
        var body: some View {
            GeneralSettings {
                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                    NavigationLink {
                        CalendarSettings()
                    } label: {
                        Label("Calendars", systemImage: "calendar")
                    }
                    NavigationLink {
                        AreasSettings()
                    } label: {
                        Label("Areas", systemImage: ItemField.area.symbol)
                    }
                    NavigationLink {
                        ContextsSettings()
                    } label: {
                        Label("Contexts", systemImage: ItemField.contexts.symbol)
                    }
                }
            }
        }
    #endif
}

/// The settings that aren't areas or contexts, with `more` at the end.
private struct GeneralSettings<More: View>: View {
    @ViewBuilder var more: More

    var body: some View {
        Form {
            SyncSettings()
            #if os(macOS)
                ShortcutSettings()
            #endif
            BrainDumpSettings()
            #if os(iOS)
                ExportSettings()
            #endif
            more
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

extension GeneralSettings where More == EmptyView {
    init() {
        more = EmptyView()
    }
}

/// Whether sync is on and what it's doing, in plain words.
private struct SyncSettings: View {
    @Environment(CloudSync.self) private var cloudSync

    var body: some View {
        Section {
            LabeledContent("iCloud Account", value: cloudSync.account ?? "Checking…")
            Toggle(
                "Sync with iCloud",
                isOn: Binding(
                    get: { cloudSync.isOn },
                    set: { on in
                        if on { Task { await cloudSync.turnOn() } } else { cloudSync.turnOff() }
                    })
            )
            .disabled(cloudSync.isWorking)
            if cloudSync.isOn {
                LabeledContent("Waiting to Send", value: "\(cloudSync.pendingCount)")
                LabeledContent("Last Sent", value: Self.time(cloudSync.lastSent))
                LabeledContent("Last Checked for Changes", value: Self.time(cloudSync.lastFetched))
                if let result = cloudSync.lastResult {
                    Text(result).foregroundStyle(.secondary)
                }
                Button(cloudSync.isSyncing ? "Syncing…" : "Sync Now") { cloudSync.syncNow() }
                    .disabled(cloudSync.isSyncing)
            }
            if let problem = cloudSync.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
            }
            if let message = cloudSync.message {
                Text(message).foregroundStyle(.secondary)
            }
            ForEach(cloudSync.lostEdits, id: \.self) { lost in
                Text("\(lost) was deleted on another device before your change reached iCloud.")
                    .foregroundStyle(.secondary)
            }
            ConflictedCopies()
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("Your tasks stay in your own iCloud account. Changes are saved on this device as you make them, and sent within a few seconds.")
        }
        .task { await cloudSync.checkAccount() }
    }

    private static func time(_ date: Date?) -> String {
        date.map { $0.formatted(date: .omitted, time: .standard) } ?? "Not yet"
    }
}

/// Notes changed on two devices at once: the versions that didn't win, kept for 30 days.
private struct ConflictedCopies: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ConflictedCopy.createdAt, order: .reverse) private var copies: [ConflictedCopy]

    var body: some View {
        if !copies.isEmpty {
            DisclosureGroup("Conflicted Copies (\(copies.count))") {
                ForEach(copies) { copy in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy.text).lineLimit(4)
                        Text(copy.createdAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            model.context.delete(copy)
                            model.save()
                        }
                    }
                }
                Text("The version that reached iCloud last was kept; these are the others.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#if os(macOS)
    private struct ShortcutSettings: View {
        @AppStorage(QuickCapturePanel.shortcutKey) private var shortcut = QuickCapturePanel.Shortcut.controlOptionSpace

        var body: some View {
            Section {
                Picker("Shortcut", selection: $shortcut) {
                    ForEach(QuickCapturePanel.Shortcut.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .onChange(of: shortcut) { QuickCapturePanel.shared.registerShortcut() }
            } header: {
                Text("Quick Capture")
            } footer: {
                Text("Opens a small window to add to your Inbox from any app. The menu-bar icon does the same.")
            }
        }
    }
#endif

/// The brain dump's prompts, one per line, "Title: what to think about", saved when the editor
/// loses the cursor, when it goes, and before a sync.
private struct BrainDumpSettings: View {
    @Environment(AppModel.self) private var model
    @Query private var settings: [AppSettings]
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Section {
            TextEditor(text: $text)
                .frame(minHeight: 160)
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused { save() }
                }
                .onDisappear(perform: save)
                .onReceive(NotificationCenter.default.publisher(for: .willSync)) { _ in save() }
            Button("Use the Built-in Prompts") {
                text = BrainDump.defaultLines.joined(separator: "\n")
                save()
            }
        } header: {
            Text("Brain Dump Prompts")
        } footer: {
            Text("One prompt per line, such as “Home: repairs, purchases, paperwork”.")
        }
        .onAppear {
            text = BrainDump.prompts(settings.first?.brainDumpPrompts ?? []).map(\.line).joined(separator: "\n")
        }
    }

    private func save() {
        guard let record = settings.first else { return }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let stored = lines == BrainDump.defaultLines ? [] : lines
        guard stored != record.brainDumpPrompts else { return }
        record.brainDumpPrompts = stored
        record.modifiedAt = .now
        model.save()
    }
}

#if os(iOS)
    /// Backing up everything, and restoring a backup into an empty app.
    private struct ExportSettings: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            Section {
                Button("Back Up…", systemImage: "square.and.arrow.up") { model.exportAll() }
                Button("Restore from Backup…", systemImage: "square.and.arrow.down") { model.isChoosingRestore = true }
            } header: {
                Text("Your Data")
            } footer: {
                Text(
                    "A backup is a folder with everything in it, as Markdown to read and a file to restore from. Restoring works only before anything has been added."
                )
            }
        }
    }
#endif
