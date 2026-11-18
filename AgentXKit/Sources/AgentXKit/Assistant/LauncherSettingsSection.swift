import SwiftUI

/// Settings → Assistant → Launcher and pointer.
struct LauncherSettingsSection: View {
    @AppStorage("launcherPosition") private var position = LauncherController.Position.center.rawValue
    @AppStorage(SelectionBubble.settingKey) private var bubble = true
    @AppStorage("voiceHoldToTalk") private var holdToTalk = true
    @AppStorage("voiceReadAloud") private var readAloud = false
    @AppStorage("launcherSearch") private var search = true
    @AppStorage(LocalCommands.settingKey) private var localCommands = true
    @State private var usage = (onMac: 0, claude: 0, since: Date())

    var body: some View {
        Section {
            Picker("Open the launcher", selection: $position) {
                ForEach(LauncherController.Position.allCases) { Text($0.label).tag($0.rawValue) }
            }
            toggle($search, "Search apps, files and settings",
                   "As you type: apps, files (Spotlight's index of your home folder), System Settings pages, sums and web addresses. Return opens the top one; ⌘Return asks Claude.")
            toggle($localCommands, "Do commands on this Mac with Apple Intelligence",
                   "\"Add lunch with Enda tomorrow at 1\", \"remind me to call mum at 6\", \"volume 30\": Apple's on-device model works out what you mean and AgentX does it, without Claude. Adding or quitting something waits for Return.")
            if localCommands {
                LabeledContent("Apple Intelligence") {
                    let availability = LocalCommands.shared.availability
                    Label(availability.message, systemImage: availability == .available ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(availability == .available ? .green : .secondary)
                        .font(.callout)
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Text("\(usage.onMac) on this Mac · \(usage.claude) with Claude").font(.callout).monospacedDigit()
                        Button("Reset") { LocalUsage.reset(); refreshUsage() }.controlSize(.small)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("From the launcher")
                        Text("Since \(usage.since.formatted(date: .abbreviated, time: .omitted)): commands, summaries, translations and answers done here, and what went to Claude")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onAppear(perform: refreshUsage)
            }
            toggle($bubble, "Show an Ask button when you select text",
                   "Select text in any app and a small button appears by the pointer, with Explain, Summarize, Fix the Writing and more. AgentX notices only where you let go of the mouse; nothing is read until you click it.")
            toggle($holdToTalk, "Hold the shortcut to talk",
                   "Hold it, speak, and let go to send (or click the microphone). Speech is recognized on this Mac; only the words go to Claude.")
            toggle($readAloud, "Read answers aloud when you ask by voice", "With macOS's own voices, on this Mac.")
        } header: {
            Text("Launcher and pointer")
        } footer: {
            Text("Ask where something is (\"where's the export button?\") and Claude points at it on your screen. It never clicks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshUsage() { usage = (LocalUsage.onMac, LocalUsage.claude, LocalUsage.since) }

    private func toggle(_ value: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
