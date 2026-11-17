import SwiftUI

/// The Chats section's "On this Mac" side: conversations with Claude that
/// can act on your Mac (Calendar, Reminders, files, apps, Shortcuts, Mail,
/// Notes, Messages). Each one is a Claude Code session, shown with the same
/// view as coding sessions (approvals, phone sync, terminal).
struct MacChatsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HSplitView {
            MacChatList()
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            Group {
                if let c = model.sessions.selectedAssistantConversation {
                    ConversationView(conversation: c).id(c.id)
                } else {
                    MacChatHome()
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Move “\(model.pendingTrash?.title ?? "")” to the Trash?",
                            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let pending = model.pendingTrash else { return }
                model.pendingTrash = nil
                Task { await model.trashConversation(pending.key, title: pending.title) }
            }
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
        } message: {
            Text("It's removed from AgentX and from Claude Code's history on this Mac. You can put it back from the Trash. Chats on claude.ai aren't affected.")
        }
    }
}

/// Suggestions shown on an empty Mac conversation (also used by the launcher).
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

private struct MacChatList: View {
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
                    ForEach(unsaved) { c in
                        row(c.title, detail: c.liveState?.label ?? "")
                            .tag(c.id as String?)
                            .contextMenu { trashButton(c.id, c.title) }
                    }
                }
            }
            Section("Recent") {
                ForEach(store.assistantSessions) { s in
                    row(s.title, detail: s.modifiedDate.relative)
                        .tag(s.sessionId as String?)
                        .contextMenu { trashButton(s.sessionId, s.title) }
                }
            }
        }
        .listStyle(.sidebar)
        // The Delete key (and Edit → Delete) on the selected conversation.
        .onDeleteCommand {
            guard let key = store.assistantSelectedKey else { return }
            let title = store.selectedAssistantConversation?.title
                ?? store.assistantSessions.first { $0.sessionId == key }?.title ?? "Conversation"
            model.pendingTrash = (key, title)
        }
        .overlay {
            if store.assistantSessions.isEmpty && unsaved.isEmpty {
                Text("No conversations yet").foregroundStyle(.secondary)
            }
        }
    }

    private func trashButton(_ key: String, _ title: String) -> some View {
        Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.pendingTrash = (key, title) }
    }

    private func row(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(2)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

/// Empty state: a big prompt, suggestions, and what Claude can do on your Mac.
/// Text carried over from claude.ai ("Continue on Mac") lands in the composer.
private struct MacChatHome: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    /// Set while the draft holds text carried over from claude.ai.
    @State private var carriedTaint: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "desktopcomputer").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("What can I do on your Mac?").font(.largeTitle.bold())
            if carriedTaint != nil {
                HStack(spacing: 8) {
                    Image(systemName: "cloud").foregroundStyle(.secondary)
                    Text("Brought over from claude.ai. Add what you'd like done, then send. Since it may quote web pages or files, Claude will ask before anything that sends data out.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Clear", systemImage: "xmark.circle") {
                        draft = ""
                        carriedTaint = nil
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: 640)
            }
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
        .navigationSubtitle("Can act on your Mac")
        .onAppear(perform: takeHandoff)
        .onChange(of: model.macHandoff) { takeHandoff() }
    }

    private func ask(_ text: String) {
        let taint = carriedTaint
        carriedTaint = nil
        Task { await model.askAssistant(text, taint: taint) }
    }

    private func takeHandoff() {
        guard let handoff = model.macHandoff else { return }
        draft = handoff.text
        carriedTaint = handoff.taint
        model.macHandoff = nil
    }
}

/// Suggestion chips: capsules sized to their text, wrapping onto new lines.
struct FlowSuggestions: View {
    let ask: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(AssistantSuggestions.all, id: \.self) { suggestion in
                Button(suggestion) { ask(suggestion) }
                    .secondaryButton()
                    .lineLimit(1)
            }
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
            .readingColumn()
            .padding(.horizontal, 28)
            .padding(.top, 8)
        }
    }
}
