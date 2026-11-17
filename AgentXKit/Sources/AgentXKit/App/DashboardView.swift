import SwiftUI

/// The home screen: account, agents at work, recent sessions, today's agenda,
/// vitals, automations and GitHub.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    AgentsCard()
                    AccountCard()
                    RecentSessionsCard()
                    VitalsCard()
                    TodayCard()
                    AutomationsCard()
                }
                GitHubActivityCard()
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.largeTitle.bold())
                Text(Date.now.formatted(date: .complete, time: .omitted)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Chat", systemImage: "bubble.left.and.text.bubble.right") { model.newChat() }
                .secondaryButton()
                .controlSize(.large)
                .help("A new chat in Claude, on this Mac or on claude.ai (whichever you used last)")
            Button("New Session", systemImage: "plus") { model.showNewSession = true }
                .primaryButton()
                .controlSize(.large)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

}

/// CPU, memory, disk and battery at a glance; Details opens System.
private struct VitalsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard("Mac vitals", symbol: "gauge.with.dots.needle.50percent") {
            Button("Details") { model.sidebar = .system }.buttonStyle(.link)
        } content: {
            if let s = model.system.latest {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("CPU", Format.percent(s.cpu), s.cpu)
                    row("Memory", "\(Format.bytes(s.memory.used)) of \(Format.bytes(s.memory.total))", s.memory.usedFraction)
                    row("Disk", "\(Format.bytes(s.disk.available)) free", s.disk.usedFraction)
                    if let b = s.battery {
                        row("Battery", Format.percent(b.level) + (b.isCharging ? ", charging" : ""), b.level)
                    }
                }
                if s.memoryPressure != .normal {
                    StatusLabel(level: s.memoryPressure.statusLevel, text: "\(s.memoryPressure.label) memory pressure")
                }
            } else {
                Text("Reading your Mac's vitals…").foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 140)
        .onAppear { model.system.beginWatching() }
        .onDisappear { model.system.endWatching() }
    }

    private func row(_ name: String, _ value: String, _ fraction: Double) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            CapacityBar(fraction: fraction, height: 8).frame(width: 90)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

private struct AgentsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.sessions.liveConversations
        let approvals = model.sessions.approvals
        GlassCard("Agents", symbol: "bolt.horizontal.circle") {
            Text("\(live.count) running").font(.caption).foregroundStyle(.secondary)
        } content: {
            if live.isEmpty && approvals.isEmpty {
                Text("No sessions running in AgentX.").foregroundStyle(.secondary)
            }
            ForEach(approvals) { approval in
                HStack {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text(approval.headline).lineLimit(1)
                    Spacer()
                    Button("Deny") { model.sessions.answer(approval, .deny()) }.secondaryButton()
                    Button("Allow") { model.sessions.answer(approval, .allow) }.primaryButton()
                }
                .font(.callout)
            }
            ForEach(live) { c in
                Button { model.openSession(c.sessionId ?? c.id) } label: {
                    HStack {
                        Text(c.title).lineLimit(1)
                        Spacer()
                        if let state = c.liveState { StateBadge(state: state) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 140)
    }
}

private struct AccountCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard("Claude", symbol: "person.crop.circle") {
            if model.isLoadingAccount { ProgressView().controlSize(.small) }
        } content: {
            switch model.client.status {
            case .failed(let why):
                Text(why).foregroundStyle(.red).font(.callout)
            case .starting, .stopped:
                Text("Starting the agent engine…").foregroundStyle(.secondary)
            case .ready:
                if let account = model.account?.account {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account.planLabel).font(.title2.bold())
                        if let email = account.email { Text(email).foregroundStyle(.secondary) }
                        if !account.isSignedIn {
                            Button("Sign In…") { model.showLogin = true }.primaryButton()
                        }
                        if let usage = model.usage.usage {
                            UsageMeter(usage: usage)
                                .padding(.top, 4)
                        }
                        Text("Engine: Agent SDK \(model.client.sdkVersion ?? "?")").font(.caption).foregroundStyle(.tertiary)
                    }
                } else if let error = model.accountError {
                    Text(error).foregroundStyle(.red).font(.callout)
                } else {
                    Text("Loading account…").foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 140)
    }
}

private struct RecentSessionsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard("Recent sessions", symbol: "clock") {
            Button("All") { model.sidebar = .sessions }.buttonStyle(.link)
        } content: {
            let recent = model.sessions.codingSessions.prefix(6)
            if recent.isEmpty {
                Text(model.sessions.isRefreshing ? "Loading…" : "No sessions yet.").foregroundStyle(.secondary)
            }
            ForEach(recent) { s in
                Button { model.openSession(s.sessionId) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).lineLimit(1)
                            Text(s.projectName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(s.modifiedDate.relative).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 140)
    }
}
