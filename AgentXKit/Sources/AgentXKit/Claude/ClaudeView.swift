import SwiftUI

/// The Claude section: one place to talk to Claude, with two sides.
///
/// - **On this Mac**: Claude Code with AgentX's Mac tools (Calendar, files,
///   apps, settings, Mail…), approvals and the security policy. Also what the
///   ⌥Space launcher talks to.
/// - **claude.ai**: your regular chats, the same ones as the Claude app on
///   your phone. It runs in Anthropic's cloud and can't act on your Mac.
///
/// The two keep separate histories (claude.ai's isn't available to apps), so
/// "Continue on Mac" and "Continue in claude.ai" carry the text across.
struct ClaudeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.claudeMode {
            case .mac: MacChatsView()
            case .web: ClaudeWebPane()
            }
        }
        .navigationTitle("Claude")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Where", selection: $model.claudeMode) {
                    ForEach(ClaudeMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("On this Mac: \(ClaudeMode.mac.explanation)\nclaude.ai: \(ClaudeMode.web.explanation)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help(model.claudeMode == .mac
                          ? "New conversation on this Mac (⇧⌘N)"
                          : "New claude.ai chat (⇧⌘N)")
            }
        }
    }
}
