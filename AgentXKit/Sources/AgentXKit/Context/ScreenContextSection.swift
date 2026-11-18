import SwiftUI

/// Settings → Assistant → What's on your screen.
struct ScreenContextSection: View {
    @AppStorage("contextMode") private var mode = LauncherController.ContextMode.include.rawValue
    @AppStorage(SelectionCopier.settingKey) private var copyFallback = true
    @State private var accessibility = AXReader.isTrusted
    @State private var screenRecording = ScreenGrabber.hasPermission

    var body: some View {
        Section {
            Picker("When you open the launcher", selection: $mode) {
                ForEach(LauncherController.ContextMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle(isOn: $copyFallback) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Copy the selection when an app hides it")
                    Text("Chrome and similar browsers don't share selected text, so AgentX presses ⌘C in that app and puts your clipboard back right after. Never in password fields, Finder or password managers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent {
                status(accessibility, fix: "Allow…") {
                    AXReader.requestTrust()
                    AXReader.openSettings()
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility")
                    Text("Window titles and selected text (never password fields)").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent {
                status(screenRecording, fix: "Allow…") {
                    ScreenGrabber.requestPermission()
                    ScreenGrabber.openSettings()
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                    Text("Look at Window, and Claude's screen_look (asks every time)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("What's on your screen")
        } footer: {
            Text("AgentX looks only when you open the launcher (or when Claude asks, in a conversation you're in): the app in front, its window, your selection, the browser tab or Finder's selection. Each shows as a chip you can remove before sending. Pictures are taken only when you click Look at Window. A conversation that gets any of this asks before anything that could send data out. After allowing Screen Recording, quit and reopen AgentX.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        accessibility = AXReader.isTrusted
        screenRecording = ScreenGrabber.hasPermission
    }

    @ViewBuilder private func status(_ on: Bool, fix: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if on {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Off", systemImage: "xmark.circle").foregroundStyle(.secondary)
                Button(fix, action: action).controlSize(.small)
            }
        }
        .font(.callout)
    }
}
