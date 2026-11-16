import SwiftUI

/// Assistant section: chats with Claude that can act on your Mac
/// (Calendar, Reminders, Files, Apps, Shortcuts, Mail, Notes, Messages).
struct AssistantView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            AssistantList()
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            Group {
                if let c = model.sessions.selectedAssistantConversation {
                    AssistantChatView(conversation: c).id(c.id)
                } else {
                    AssistantHome()
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Assistant")
    }
}

/// Suggestions shown on an empty assistant (also used by the launcher).
enum AssistantSuggestions {
    static let all = [
        "What's on my calendar today?",
        "Remind me to call the bank tomorrow at 10am",
        "Find the PDFs I downloaded this week",
        "Summarize my unread email",
        "Turn on dark mode",
        "Which of my Shortcuts could help me focus?",
    ]
}

private struct AssistantList: View {
    @Environment(AppModel.self) private var model

    private var store: SessionStore { model.sessions }

    /// New conversations not yet in the on-disk list.
    private var unsaved: [Conversation] {
        let known = Set(store.assistantSessions.map(\.sessionId))
        return store.conversations.values
            .filter { $0.kind == .assistant && ($0.sessionId.map { !known.contains($0) } ?? true) }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        let selection = Binding<String?>(get: { store.assistantSelectedKey }, set: { store.selectAssistant($0) })
        List(selection: selection) {
            if !unsaved.isEmpty {
                Section("Now") {
                    ForEach(unsaved) { c in row(c.title, detail: c.liveState?.label ?? "").tag(c.id as String?) }
                }
            }
            Section("Recent") {
                ForEach(store.assistantSessions) { s in
                    row(s.title, detail: s.modifiedDate.relative).tag(s.sessionId as String?)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.assistantSessions.isEmpty && unsaved.isEmpty {
                Text("No conversations yet").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            Button("New Conversation", systemImage: "square.and.pencil") { store.selectAssistant(nil) }
        }
    }

    private func row(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(2)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

/// Empty state: a big prompt, suggestions, and what the assistant can do.
private struct AssistantHome: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("What can I do on your Mac?").font(.largeTitle.bold())
            Composer(text: $draft, isWorking: false, send: ask, stop: {})
                .frame(maxWidth: 640)
            FlowSuggestions(ask: ask)
                .frame(maxWidth: 640)
            Text("Calendar · Reminders · Files · Apps · Shortcuts · Mail · Notes · Messages\nReading and creating run right away; sending, deleting, moving and quitting ask you first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    private func ask(_ text: String) {
        Task { await model.askAssistant(text) }
    }
}

/// Suggestion chips that wrap onto new lines.
struct FlowSuggestions: View {
    let ask: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
            ForEach(AssistantSuggestions.all, id: \.self) { suggestion in
                Button { ask(suggestion) } label: {
                    Text(suggestion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
            }
        }
    }
}

struct AssistantChatView: View {
    @Environment(AppModel.self) private var model
    @Bindable var conversation: Conversation
    @State private var draft = ""

    private var store: SessionStore { model.sessions }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(conversation.title).font(.headline).lineLimit(1)
                Spacer()
                if let state = conversation.liveState { StateBadge(state: state) }
                if conversation.isLive {
                    Button("End", systemImage: "stop.circle") { Task { await store.stop(conversation) } }
                        .help("Stop this conversation's Claude Code process. You can pick it up again later.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            TranscriptView(conversation: conversation)
            ApprovalList(conversation: conversation)
            Composer(text: $draft, isWorking: conversation.isWorking,
                     send: { text in Task { await store.send(text, in: conversation) } },
                     stop: { Task { await store.interrupt(conversation) } })
        }
    }
}

/// Approval cards for one conversation.
struct ApprovalList: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let pending = model.sessions.approvals(for: conversation)
        if !pending.isEmpty {
            VStack(spacing: 8) {
                ForEach(pending) { approval in
                    ApprovalCard(approval: approval) { answer in model.sessions.answer(approval, answer) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}
