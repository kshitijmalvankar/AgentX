import SwiftUI

/// Menu bar icon: changes when Claude is working or needs you.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let approvals = model.sessions.approvals.count
        let working = model.sessions.liveConversations.contains { $0.liveState == .running }
        if approvals > 0 {
            Label("\(approvals)", systemImage: "hand.raised.fill")
        } else {
            Image(systemName: working ? "sparkles" : "sparkle")
        }
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
                Text("AgentX").font(.headline)
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

            if let limit = model.sessions.latestRateLimit, let u = limit.utilization {
                Gauge(value: min(max(u, 0), 1)) { Text("Plan usage \(Int(u * 100))%").font(.caption) }
                    .gaugeStyle(.linearCapacity)
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
                            Button("Deny") { model.sessions.answer(approval, .deny()) }
                            Spacer()
                            Button("Allow") { model.sessions.answer(approval, .allow) }.buttonStyle(.glassProminent)
                        }
                    }
                    .padding(10)
                    .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 12))
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
            }

            Divider()
            HStack {
                Button("Open AgentX") { openMain() }
                Button("New Chat") { openMain(); model.startNewChat() }
                Button("New Session") { openMain(); model.showNewSession = true }
                Spacer()
                Button("Settings", systemImage: "gearshape") { NSApp.activate(); openSettings() }
                    .labelStyle(.iconOnly)
                Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
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
}
