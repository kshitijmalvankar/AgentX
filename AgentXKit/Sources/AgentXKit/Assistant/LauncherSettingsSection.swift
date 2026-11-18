import SwiftUI

/// Settings → Assistant → Launcher and pointer.
struct LauncherSettingsSection: View {
    @AppStorage("launcherPosition") private var position = LauncherController.Position.center.rawValue
    @AppStorage(SelectionBubble.settingKey) private var bubble = true
    @AppStorage("voiceHoldToTalk") private var holdToTalk = true
    @AppStorage("voiceReadAloud") private var readAloud = false

    var body: some View {
        Section {
            Picker("Open the launcher", selection: $position) {
                ForEach(LauncherController.Position.allCases) { Text($0.label).tag($0.rawValue) }
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

    private func toggle(_ value: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
