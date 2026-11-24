import SwiftUI

/// Menu bar icon: changes when Claude is working or needs you.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let approvals = model.sessions.approvals.count
        let working = model.sessions.liveConversations.contains { $0.liveState == .running }
        Group {
            if approvals > 0 {
                Label("\(approvals)", systemImage: "hand.raised.fill")
            } else if AppChannel.current.isDev {
                // AgentX Dev's icon looks different so you can tell the two apart.
                Image(systemName: working ? "hammer.fill" : "hammer")
            } else {
                Image(systemName: working ? "sparkles" : "sparkle")
            }
        }
        // The status item always exists, so it's where the launcher gets a
        // way to reopen the main window after it was closed.
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

/// The dropdown window from the menu bar.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(AppChannel.current.displayName).font(.headline)
                if model.automations.isPaused {
                    Label("Automations paused", systemImage: "pause.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help("Automations are paused. Turn them back on in Automations.")
                }
                Spacer()
                Text(model.account?.account.planLabel ?? model.client.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let s = model.system.latest {
                HStack(spacing: 12) {
                    Label(Format.percent(s.cpu), systemImage: "cpu")
                    Label(Format.percent(s.memory.usedFraction), systemImage: "memorychip")
                    if let b = s.battery {
                        Label(Format.percent(b.level), systemImage: b.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                    }
                    Spacer()
                    Button("Details") { openMain(); model.sidebar = .system }.buttonStyle(.link)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if let usage = model.usage.usage {
                UsageMeter(usage: usage, compact: true)
            }

            let approvals = model.sessions.approvals
            if !approvals.isEmpty {
                Text("Needs your OK").font(.subheadline.bold())
                ForEach(approvals) { approval in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(approval.headline).font(.callout).lineLimit(2)
                        Text(ToolPresentation.summary(name: approval.toolName, input: approval.input, cwd: approval.cwd))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack {
                            if approval.isQuestion {
                                Spacer()
                                Button("Answer…") { answerInApp(approval) }.primaryButton()
                            } else {
                                Button("Deny") { model.sessions.answer(approval, .deny()) }.secondaryButton()
                                Spacer()
                                Button("Allow") { model.sessions.answer(approval, .allow) }.primaryButton()
                            }
                        }
                    }
                    .padding(10)
                    .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .agentCard)
                }
            }

            let live = model.sessions.liveConversations
            if !live.isEmpty {
                Text("Running").font(.subheadline.bold())
                ForEach(live) { c in
                    Button { show(c.sessionId ?? c.id) } label: {
                        HStack {
                            Text(c.title).lineLimit(1)
                            Spacer()
                            if let state = c.liveState { StateBadge(state: state) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if live.isEmpty && approvals.isEmpty {
                Text("Nothing running.").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Stop Everything", systemImage: "stop.circle", role: .destructive) {
                    Task { await model.stopEverything(source: "the menu bar") }
                }
                .secondaryButton()
                .controlSize(.small)
                .help("Stop every running Claude session, deny what's waiting, and pause automations (⌃⌥⌘. by default)")
            }

            Divider()
            HStack(spacing: 8) {
                Button("Ask…") { LauncherController.shared.show() }
                    .primaryButton()
                    .help("Open the launcher (⌥Space by default)")
                Button("New Chat") { openMain(); model.newChat() }
                    .secondaryButton()
                Button("New Session") { openMain(); model.showNewSession = true }
                    .secondaryButton()
            }
            .controlSize(.small)
            HStack {
                Button("Open AgentX") { openMain() }
                    .buttonStyle(.link)
                Spacer()
                Button("Settings", systemImage: "gearshape") { NSApp.activate(); openSettings() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { model.system.beginWatching() }
        .onDisappear { model.system.endWatching() }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private func show(_ key: String) {
        model.openSession(key)
        openMain()
    }

    /// A question is answered on its card in the session.
    private func answerInApp(_ approval: ApprovalRequest) {
        if let key = model.sessions.conversationKey(for: approval) { show(key) } else { openMain() }
    }
}
