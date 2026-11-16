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
                            .buttonStyle(.glassProminent)
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

    private var store: SessionStore { model.sessions }

    private var filtered: [SessionSummary] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.sessions }
        return store.sessions.filter {
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
        return store.liveConversations.filter { $0.sessionId.map { !known.contains($0) } ?? true }
    }

    var body: some View {
        let selection = Binding<String?>(get: { store.selectedKey }, set: { store.select($0) })
        List(selection: selection) {
            if !newLive.isEmpty {
                Section("Starting") {
                    ForEach(newLive) { c in
                        LiveRow(conversation: c).tag(c.id as String?)
                    }
                }
            }
            ForEach(groups, id: \.project) { group in
                Section {
                    ForEach(group.sessions) { s in
                        SessionRow(summary: s, live: store.conversation(forSessionId: s.sessionId))
                            .tag(s.sessionId as String?)
                    }
                } header: {
                    HStack {
                        Text((group.project as NSString).lastPathComponent)
                        Spacer()
                        Text("\(group.sessions.count)").foregroundStyle(.tertiary)
                    }
                    .help(group.project.abbreviatingHome)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search sessions")
        .overlay {
            if store.sessions.isEmpty {
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.title)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let state = live?.liveState {
                    Image(systemName: state.symbol)
                        .foregroundStyle(state == .waiting ? .orange : .blue)
                        .symbolEffect(.pulse, isActive: state == .running || state == .waiting)
                }
            }
            HStack(spacing: 6) {
                Text(summary.modifiedDate.relative)
                if let branch = summary.gitBranch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
