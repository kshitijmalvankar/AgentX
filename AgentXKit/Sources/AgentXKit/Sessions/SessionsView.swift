import SwiftUI

/// Sessions section: every Claude Code session on this Mac on the left,
/// the selected conversation on the right.
struct SessionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            SessionListView()
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
            Group {
                if let conversation = model.sessions.selectedConversation {
                    ConversationView(conversation: conversation)
                        .id(conversation.id)
                } else {
                    ContentUnavailableView {
                        Label("No session selected", systemImage: "terminal")
                    } description: {
                        Text("Pick a session on the left, or start a new one.")
                    } actions: {
                        Button("New Session", systemImage: "plus") { model.showNewSession = true }
                            .primaryButton()
                    }
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    /// Projects you folded or unfolded; others follow `defaultExpanded`.
    @State private var expandedOverride: [String: Bool] = [:]

    private var store: SessionStore { model.sessions }

    /// Recently active projects start open; older ones start folded.
    private func defaultExpanded(_ sessions: [SessionSummary]) -> Bool {
        guard let latest = sessions.first?.modifiedDate else { return false }
        return Date().timeIntervalSince(latest) < 14 * 86_400
    }

    private func isExpanded(_ group: (project: String, sessions: [SessionSummary])) -> Binding<Bool> {
        Binding(
            get: { !search.isEmpty || (expandedOverride[group.project] ?? defaultExpanded(group.sessions)) },
            set: { expandedOverride[group.project] = $0 }
        )
    }

    private var filtered: [SessionSummary] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.codingSessions }
        return store.codingSessions.filter {
            $0.title.lowercased().contains(q) || ($0.cwd ?? "").lowercased().contains(q) || ($0.gitBranch ?? "").lowercased().contains(q)
        }
    }

    /// Group by project folder, most recently active project first.
    private var groups: [(project: String, sessions: [SessionSummary])] {
        var order: [String] = []
        var byProject: [String: [SessionSummary]] = [:]
        for s in filtered {
            let key = s.cwd ?? "Unknown"
            if byProject[key] == nil { order.append(key) }
            byProject[key, default: []].append(s)
        }
        return order.map { ($0, byProject[$0]!) }
    }

    /// Live conversations that aren't in the on-disk list yet (brand-new sessions).
    private var newLive: [Conversation] {
        let known = Set(store.sessions.map(\.sessionId))
        return store.liveConversations.filter { $0.kind == .coding && ($0.sessionId.map { !known.contains($0) } ?? true) }
    }

    var body: some View {
        let selection = Binding<String?>(get: { store.selectedKey }, set: { store.select($0) })
        List(selection: selection) {
            if !newLive.isEmpty {
                Section("Running") {
                    ForEach(newLive) { c in
                        LiveRow(conversation: c).tag(c.id as String?)
                    }
                }
            }
            ForEach(groups, id: \.project) { group in
                Section(isExpanded: isExpanded(group)) {
                    ForEach(group.sessions) { s in
                        SessionRow(summary: s, live: store.conversation(forSessionId: s.sessionId))
                            .tag(s.sessionId as String?)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text((group.project as NSString).lastPathComponent)
                        Spacer()
                        Text("\(group.sessions.count)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .help(group.project.abbreviatingHome)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search sessions")
        .overlay {
            if store.codingSessions.isEmpty {
                if store.isRefreshing { ProgressView() }
                else if let error = store.refreshError {
                    ContentUnavailableView("Couldn't load sessions", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if model.client.status == .ready {
                    ContentUnavailableView("No sessions yet", systemImage: "terminal")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
                Button("New Session", systemImage: "plus") { model.showNewSession = true }
            }
        }
    }
}

private struct SessionRow: View {
    let summary: SessionSummary
    let live: Conversation?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .fontWeight(live?.liveState != nil ? .medium : .regular)
                    .lineLimit(2)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let state = live?.liveState {
                Image(systemName: state.symbol)
                    .font(.caption)
                    .foregroundStyle(state == .waiting ? .orange : .blue)
                    .symbolEffect(.pulse, isActive: state == .running || state == .waiting)
                    .help(state.label)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
    }

    /// "2h ago · main" (a detached HEAD isn't worth showing).
    private var meta: String {
        var parts = [summary.modifiedDate.relative]
        if let branch = summary.gitBranch, !branch.isEmpty, branch != "HEAD" { parts.append(branch) }
        return parts.joined(separator: " · ")
    }
}

private struct LiveRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title).lineLimit(2)
            HStack {
                Text(conversation.projectName)
                if let state = conversation.liveState { StateBadge(state: state) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
