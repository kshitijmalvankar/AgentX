import SwiftUI

/// The home screen: account, agents at work, recent sessions, and slots for
/// the pillars still to come.
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
                    upcoming("Mac vitals", symbol: "gauge.with.dots.needle.50percent", text: "CPU, memory, battery and network at a glance.", milestone: "M2")
                    upcoming("Today", symbol: "calendar", text: "Your agenda and reminders, from Calendar.", milestone: "M3")
                    upcoming("Automations", symbol: "clock.arrow.2.circlepath", text: "Next scheduled runs and their results.", milestone: "M4")
                }
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
            Button("New Session", systemImage: "plus") { model.showNewSession = true }
                .buttonStyle(.glassProminent)
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

    private func upcoming(_ title: String, symbol: String, text: String, milestone: String) -> some View {
        GlassCard(title, symbol: symbol) {
            Text(milestone).font(.caption.bold()).foregroundStyle(.secondary)
        } content: {
            Text(text).foregroundStyle(.secondary)
        }
        .frame(minHeight: 140)
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
                    Button("Deny") { model.sessions.answer(approval, .deny()) }
                    Button("Allow") { model.sessions.answer(approval, .allow) }.buttonStyle(.glassProminent)
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
                            Button("Sign In…") { model.showLogin = true }.buttonStyle(.glassProminent)
                        }
                        if let limit = model.sessions.latestRateLimit, let utilization = limit.utilization {
                            Gauge(value: min(max(utilization, 0), 1)) {
                                Text("Plan usage")
                            } currentValueLabel: {
                                Text("\(Int(utilization * 100))%")
                            }
                            .gaugeStyle(.linearCapacity)
                            if let resets = limit.resetsAt {
                                Text("Resets \(resets.relative)").font(.caption).foregroundStyle(.secondary)
                            }
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
            let recent = model.sessions.sessions.prefix(6)
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
