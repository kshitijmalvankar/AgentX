import SwiftUI

/// The home screen, work first: what needs you (pull requests, approvals),
/// what's running, recent sessions and repos with work in progress, your
/// GitHub activity; then your day; then your plan and this Mac.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                StatusStrip()

                section("Work") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        PullRequestsCard()
                        AgentsCard()
                        RecentSessionsCard()
                        WorkInProgressCard()
                    }
                    GitHubActivityCard()
                }

                section("Your day") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        TodayCard()
                        AutomationsCard()
                    }
                }

                section("Claude and this Mac") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        PlanCard()
                        VitalsCard()
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.github.refreshIfStale() }
        // Coming back from your editor or Terminal: pick up edits to files (commits show up by themselves).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.github.refreshIfStale()
        }
        .navigationTitle("Dashboard")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text(greeting).font(.system(size: 34, weight: .bold))
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
        let name = model.github.snapshot?.profile.name?.split(separator: " ").first.map(String.init)
        let hello = switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        return name.map { "\(hello), \($0)" } ?? hello
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .padding(.leading, 4)
            content()
        }
    }
}

// MARK: At a glance

/// What needs you, in one line of pills; each opens the place to deal with it.
private struct StatusStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = model.sessions.liveConversations.filter(\.isWorking).count
        let waiting = model.sessions.approvals.count
        let prs = model.github.pullRequests
        FlowLayout(spacing: 8, lineSpacing: 8) {
            if waiting > 0 {
                pill("\(waiting) waiting for you", "hand.raised.fill", .orange) { model.sidebar = .sessions }
            }
            pill(running == 0 ? "No agents running" : "\(running) running", "bolt.fill", running == 0 ? .secondary : .green) {
                model.sidebar = .sessions
            }
            if let prs {
                if !prs.toReview.isEmpty {
                    pill("\(prs.toReview.count) to review", "eye.fill", .purple) { model.sidebar = .github }
                }
                pill(prs.mine.isEmpty ? "No open PRs" : "\(prs.mine.count) open PR\(prs.mine.count == 1 ? "" : "s")",
                     "arrow.triangle.pull", .indigo) { model.sidebar = .github }
                if prs.failing > 0 {
                    pill("\(prs.failing) failing", "xmark.octagon.fill", .red) { model.sidebar = .github }
                }
            }
            if let usage = model.usage.usage, let highest = usage.highest {
                pill("\(Format.percent(highest)) of plan", "gauge.with.needle", highest >= 0.8 ? .orange : .blue) {}
            }
        }
    }

    private func pill(_ text: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint == .secondary ? nil : tint.opacity(0.12)), in: .capsule)
    }
}

/// A row in a dashboard card: an icon or dot, a title and subtitle, and something on the right.
private struct CardRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading.frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -8)
    }
}

/// A quiet line for an empty card ("All clear").
private struct EmptyNote: View {
    let text: String
    var symbol = "checkmark.circle"

    var body: some View {
        Label(text, systemImage: symbol).foregroundStyle(.secondary).font(.callout)
    }
}

// MARK: Work

/// Pull requests waiting for your review, and yours with their checks.
private struct PullRequestsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.github
        GlassCard("Pull Requests", symbol: "arrow.triangle.pull", tint: .indigo) {
            Button("GitHub") { model.sidebar = .github }.buttonStyle(.link)
        } content: {
            if let prs = store.pullRequests {
                if prs.toReview.isEmpty && prs.mine.isEmpty {
                    EmptyNote(text: "No open pull requests, and nothing to review.")
                }
                if !prs.toReview.isEmpty {
                    group("Review requested") {
                        ForEach(prs.toReview.prefix(4)) { pr in
                            row(pr, subtitle: "\(pr.repoName) #\(pr.number)\(pr.author.map { " · @\($0)" } ?? "")")
                        }
                    }
                }
                if !prs.mine.isEmpty {
                    group("Yours") {
                        ForEach(prs.mine.prefix(5)) { pr in
                            row(pr, subtitle: "\(pr.repoName) #\(pr.number)\(pr.isDraft ? " · draft" : "")\(reviewLabel(pr))")
                        }
                    }
                }
            } else {
                switch store.state {
                case .needsCLI, .needsSignIn, .failed:
                    HStack {
                        EmptyNote(text: "Connect GitHub to see your pull requests.", symbol: "link")
                        Spacer()
                        Button("Set Up") { model.sidebar = .github }.secondaryButton().controlSize(.small)
                    }
                default:
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(minHeight: 150)
    }

    @ViewBuilder private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ pr: GitHubPullRequest, subtitle: String) -> some View {
        CardRow(title: pr.title, subtitle: subtitle) {
            checks(pr.checks)
        } trailing: {
            if let updated = pr.updatedAt { Text(updated.relative).font(.caption).foregroundStyle(.tertiary) }
        } action: {
            NSWorkspace.shared.open(pr.url)
        }
        .help("Open \(pr.repo) #\(pr.number) on GitHub")
    }

    @ViewBuilder private func checks(_ c: GitHubPullRequest.Checks) -> some View {
        switch c {
        case .passing: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Checks passing")
        case .failing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Checks failing")
        case .pending: Image(systemName: "clock.fill").foregroundStyle(.orange).help("Checks running")
        case .none: Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary)
        }
    }

    private func reviewLabel(_ pr: GitHubPullRequest) -> String {
        switch pr.review {
        case "APPROVED": " · approved"
        case "CHANGES_REQUESTED": " · changes requested"
        default: ""
        }
    }
}

/// Sessions running in AgentX, and anything waiting for your OK.
private struct AgentsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.sessions.liveConversations
        let approvals = model.sessions.approvals
        GlassCard("Agents", symbol: "bolt.fill", tint: .green) {
            Text(live.isEmpty ? "" : "\(live.count) open").font(.caption).foregroundStyle(.secondary)
        } content: {
            if live.isEmpty && approvals.isEmpty {
                EmptyNote(text: "Nothing running. Start one with New Session.", symbol: "moon.zzz")
            }
            ForEach(approvals) { approval in
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text(approval.headline).lineLimit(1)
                    Spacer()
                    Button("Deny") { model.sessions.answer(approval, .deny()) }.secondaryButton().controlSize(.small)
                    Button("Allow") { model.sessions.answer(approval, .allow) }.primaryButton().controlSize(.small)
                }
                .font(.callout)
                .padding(8)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
            }
            ForEach(live) { c in
                CardRow(title: c.title, subtitle: c.kind == .coding ? (c.cwd as NSString).lastPathComponent : "On this Mac") {
                    Image(systemName: c.kind == .coding ? "chevron.left.forwardslash.chevron.right" : "sparkles").foregroundStyle(.secondary)
                } trailing: {
                    if let state = c.liveState { StateBadge(state: state) }
                } action: {
                    model.openSession(c.sessionId ?? c.id)
                }
            }
        }
        .frame(minHeight: 150)
    }
}

private struct RecentSessionsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard("Recent Sessions", symbol: "clock.fill", tint: .blue) {
            Button("All") { model.sidebar = .sessions }.buttonStyle(.link)
        } content: {
            let recent = model.sessions.codingSessions.prefix(5)
            if recent.isEmpty {
                EmptyNote(text: model.sessions.isRefreshing ? "Loading…" : "No coding sessions yet.", symbol: "tray")
            }
            ForEach(recent) { s in
                CardRow(title: s.title, subtitle: s.projectName) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                } trailing: {
                    Text(s.modifiedDate.relative).font(.caption).foregroundStyle(.tertiary)
                } action: {
                    model.openSession(s.sessionId)
                }
            }
        }
        .frame(minHeight: 150)
    }
}

/// Your local clones with uncommitted changes, or commits to push or pull.
private struct WorkInProgressCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dirty = model.github.clones
            .map { (repo: $0.key, clone: $0.value) }
            .filter { !$0.clone.isClean }
            .sorted { $0.clone.changes + $0.clone.ahead > $1.clone.changes + $1.clone.ahead }
        GlassCard("Work in Progress", symbol: "hammer.fill", tint: .orange) {
            if !dirty.isEmpty { Text("\(dirty.count) repo\(dirty.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
        } content: {
            if dirty.isEmpty {
                EmptyNote(text: model.github.clones.isEmpty ? "Your project repos show here once GitHub is connected."
                                                            : "Everything's committed and pushed.")
            }
            ForEach(dirty.prefix(5), id: \.repo) { item in
                CardRow(title: (item.clone.path as NSString).lastPathComponent,
                        subtitle: [item.clone.branch, item.clone.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) {
                    Image(systemName: "folder.fill").foregroundStyle(.orange)
                } trailing: {
                    Image(systemName: "arrow.up.forward.app").foregroundStyle(.tertiary).help("Start a session here")
                } action: {
                    model.pendingNewSessionFolder = item.clone.path
                    model.showNewSession = true
                }
                .help("Start a coding session in \((item.clone.path as NSString).abbreviatingWithTildeInPath)")
            }
        }
        .frame(minHeight: 150)
    }
}

// MARK: Claude and this Mac

/// Your Claude plan: the session and weekly limits as rings.
private struct PlanCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard("Claude", symbol: "sparkles", tint: Color(red: 0.85, green: 0.47, blue: 0.34)) {
            if model.isLoadingAccount { ProgressView().controlSize(.small) }
        } content: {
            switch model.client.status {
            case .failed(let why):
                Text(why).foregroundStyle(.red).font(.callout)
            case .starting, .stopped:
                EmptyNote(text: "Starting the agent engine…", symbol: "hourglass")
            case .ready:
                if let account = model.account?.account {
                    HStack(alignment: .center, spacing: 18) {
                        if let usage = model.usage.usage {
                            if let session = usage.session { ring(session) }
                            if let week = usage.weekly { ring(week) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.planLabel).font(.title3.bold())
                            if let email = account.email { Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            if !account.isSignedIn {
                                Button("Sign In…") { model.showLogin = true }.primaryButton().controlSize(.small)
                            }
                            Text("Agent SDK \(model.client.sdkVersion ?? "?")").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                } else if let error = model.accountError {
                    Text(error).foregroundStyle(.red).font(.callout)
                } else {
                    EmptyNote(text: "Loading account…", symbol: "hourglass")
                }
            }
        }
        .frame(minHeight: 150)
    }

    private func ring(_ window: UsageWindow) -> some View {
        let color: Color = window.fraction >= 0.95 ? .red : window.fraction >= 0.8 ? .orange : .accentColor
        return VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                Circle().trim(from: 0, to: max(0.01, min(1, window.fraction)))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Format.percent(window.fraction)).font(.callout.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 66, height: 66)
            Text(window.id == "five_hour" ? "Session" : "Week").font(.caption).foregroundStyle(.secondary)
            if let reset = window.resetLabel { Text(reset).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .help(window.label)
    }
}

/// CPU, memory, disk and battery at a glance; Details opens System.
private struct VitalsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard("This Mac", symbol: "gauge.with.dots.needle.50percent", tint: .mint) {
            Button("Details") { model.sidebar = .system }.buttonStyle(.link)
        } content: {
            if let s = model.system.latest {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    row("CPU", "cpu", Format.percent(s.cpu), s.cpu)
                    row("Memory", "memorychip", "\(Format.bytes(s.memory.used)) of \(Format.bytes(s.memory.total))", s.memory.usedFraction)
                    row("Disk", "internaldrive", "\(Format.bytes(s.disk.available)) free", s.disk.usedFraction)
                    if let b = s.battery {
                        row("Battery", b.isCharging ? "battery.100.bolt" : "battery.75", Format.percent(b.level) + (b.isCharging ? ", charging" : ""), b.level)
                    }
                }
                if s.memoryPressure != .normal {
                    StatusLabel(level: s.memoryPressure.statusLevel, text: "\(s.memoryPressure.label) memory pressure")
                }
            } else {
                EmptyNote(text: "Reading your Mac's vitals…", symbol: "hourglass")
            }
        }
        .frame(minHeight: 150)
        .onAppear { model.system.beginWatching() }
        .onDisappear { model.system.endWatching() }
    }

    private func row(_ name: String, _ symbol: String, _ value: String, _ fraction: Double) -> some View {
        GridRow {
            Label(name, systemImage: symbol).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            CapacityBar(fraction: fraction, height: 7).frame(minWidth: 70, maxWidth: 120)
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.callout)
    }
}
