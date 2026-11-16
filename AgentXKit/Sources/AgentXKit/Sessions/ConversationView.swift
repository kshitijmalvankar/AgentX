import SwiftUI

/// One session: chat transcript (or the real terminal), approvals, and composer.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Bindable var conversation: Conversation

    enum Tab: String, CaseIterable, Identifiable {
        case chat = "Chat", terminal = "Terminal"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .chat
    @State private var draft = ""

    private var store: SessionStore { model.sessions }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            OpenElsewhereBanner(owners: store.externalOwners(of: conversation))
            switch tab {
            case .chat:
                TranscriptView(conversation: conversation)
                approvals
                if let terminal, terminal.isRunning {
                    TerminalHostedNote(phoneSync: terminal.remoteControl) { tab = .terminal }
                } else {
                    Composer(text: $draft, isWorking: conversation.isWorking,
                             send: { text in Task { await store.send(text, in: conversation) } },
                             stop: { Task { await store.interrupt(conversation) } })
                }
            case .terminal:
                TerminalTab(conversation: conversation, startPhoneSync: startPhoneSync)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(conversation.title)
        .navigationSubtitle(conversation.cwd.abbreviatingHome)
    }

    // MARK: Header

    /// One row that never forces the pane wider than the window: the title
    /// truncates, and secondary settings live in the ⋯ menu.
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let state = conversation.liveState { StateBadge(state: state) }

            Button {
                if phoneSyncOn { tab = .terminal } else { startPhoneSync() }
            } label: {
                Image(systemName: phoneSyncOn ? "iphone.radiowaves.left.and.right" : "iphone")
                    .foregroundStyle(phoneSyncOn ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(phoneSyncOn ? "Phone sync is on: open the Claude app on your phone, then Code."
                              : "Continue on phone: run this session with Remote Control so you can keep going from the Claude app.")

            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu {
                Menu("Model: \(modelLabel)") {
                    Button { Task { await store.setModel(nil, for: conversation) } } label: {
                        checked(conversation.model == nil, "Default")
                    }
                    ForEach(model.models) { m in
                        Button { Task { await store.setModel(m.value, for: conversation) } } label: {
                            checked(conversation.model == m.value, m.displayName)
                        }
                    }
                }
                Menu("Permissions: \(conversation.permissionMode.shortLabel)") {
                    ForEach(PermissionModeOption.allCases) { mode in
                        Button { Task { await store.setPermissionMode(mode, for: conversation) } } label: {
                            checked(mode == conversation.permissionMode, mode.label)
                        }
                    }
                }
                Divider()
                Button(phoneSyncOn ? "Show Phone Sync" : "Continue on Phone", systemImage: "iphone") {
                    if phoneSyncOn { tab = .terminal } else { startPhoneSync() }
                }
                if conversation.isLive {
                    Divider()
                    Button("End Session", systemImage: "stop.circle", role: .destructive) {
                        Task { await store.stop(conversation) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model, permissions, phone sync, end session")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func checked(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// "AgentX · main · Opus": project, branch (not a detached HEAD), and any non-default settings.
    private var subtitle: String {
        var parts = [conversation.projectName]
        if let branch = conversation.gitBranch, !branch.isEmpty, branch != "HEAD" { parts.append(branch) }
        if conversation.model != nil { parts.append(modelLabel) }
        if conversation.permissionMode != .default { parts.append(conversation.permissionMode.shortLabel) }
        return parts.joined(separator: " · ")
    }

    private var terminal: TerminalSession? { model.terminals.session(for: conversation.id) }
    private var phoneSyncOn: Bool { terminal?.remoteControl == true && terminal?.isRunning == true }

    /// Hand the session to the real Claude Code CLI with Remote Control on.
    /// The chat process (if any) is ended first so only one process writes to it.
    private func startPhoneSync() {
        tab = .terminal
        Task {
            if conversation.isLive {
                await store.stop(conversation)
                for _ in 0..<40 where conversation.isLive { try? await Task.sleep(for: .milliseconds(100)) }
            }
            model.openTerminal(for: conversation, remoteControl: true)
        }
    }

    private var modelLabel: String {
        guard let m = conversation.model else { return "Default" }
        return model.models.first(where: { $0.value == m || m.hasPrefix($0.value) })?.displayName ?? m
    }

    // MARK: Approvals

    @ViewBuilder private var approvals: some View {
        let pending = store.approvals(for: conversation)
        if !pending.isEmpty {
            VStack(spacing: 8) {
                ForEach(pending) { approval in
                    ApprovalCard(approval: approval) { answer in store.answer(approval, answer) }
                }
            }
            .readingColumn()
            .padding(.horizontal, 28)
            .padding(.top, 8)
        }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let conversation: Conversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if conversation.isLoadingHistory && conversation.items.isEmpty {
                        ProgressView("Loading history…").frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if let error = conversation.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .padding(.bottom, 12)
                    }
                    ForEach(Array(conversation.items.enumerated()), id: \.element.id) { index, item in
                        TranscriptRow(item: item, cwd: conversation.cwd)
                            .padding(.top, index == 0 ? 0 : Self.gap(after: conversation.items[index - 1].kind, before: item.kind))
                    }
                    liveTail
                    Color.clear.frame(height: 1).id("bottom")
                }
                .readingColumn()
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            // Short conversations start at the top; new messages keep the view at the bottom.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: conversation.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.draftText.count / 200) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// What's streaming in right now.
    @ViewBuilder private var liveTail: some View {
        if !conversation.draftText.isEmpty {
            Text(conversation.draftText)
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        } else if conversation.liveState == .running || conversation.liveState == .starting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(conversation.draftThinking.isEmpty ? "Working…" : "Thinking…")
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.top, 12)
        }
    }

    /// Tool calls sit close together; messages get room to breathe.
    static func gap(after previous: TranscriptKind, before item: TranscriptKind) -> CGFloat {
        switch (previous, item) {
        case (.tool, .tool), (.thinking, .tool), (.tool, .thinking): 2
        case (_, .result): 4
        case (.user, _), (_, .user): 22
        default: 12
        }
    }
}

/// Shown when another app (the Claude app, a terminal, ...) has this session open.
private struct OpenElsewhereBanner: View {
    let owners: [ExternalSession]

    var body: some View {
        if !owners.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also open in \(names)").fontWeight(.medium)
                    Text("Messages you send here continue this same session from its newest message, but that app won't show them until the session is reopened there. Use one app at a time: whichever sends last becomes the newest point.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.08))
        }
    }

    private var names: String {
        let unique = Array(Set(owners.map(\.appName))).sorted()
        return ListFormatter.localizedString(byJoining: unique)
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let cwd: String

    var body: some View {
        switch item.kind {
        case .user(let text):
            UserBubble(text: text)
        case .assistant(let text):
            MarkdownText(text: text)
        case .thinking(let text):
            ThinkingRow(text: text)
        case .tool(let call):
            ToolCallCard(call: call, cwd: cwd)
        case .notice(let text, let isError):
            Text(text)
                .font(.caption)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
        case .result(let summary):
            ResultFooter(summary: summary)
        }
    }
}

/// Your message, right-aligned. Long ones (like a pasted report) fold to 8 lines.
private struct UserBubble: View {
    let text: String
    @State private var expanded = false

    private var isLong: Bool { text.count > 600 || text.filter { $0 == "\n" }.count > 8 }

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .lineLimit(isLong && !expanded ? 8 : nil)
                    .textSelection(.enabled)
                if isLong {
                    Button(expanded ? "Show less" : "Show more") {
                        withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 16))
            .frame(maxWidth: 560, alignment: .trailing)
        }
    }
}

/// Claude's reasoning summary, folded away.
private struct ThinkingRow: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle").frame(width: 16)
                    Text("Thought it through")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.tertiary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            }
        }
    }
}

/// "Done in 8s" under a finished reply (errors stand out).
private struct ResultFooter: View {
    let summary: RunSummary

    var body: some View {
        if summary.isError {
            Label("Stopped: \(summary.subtype.replacingOccurrences(of: "_", with: " "))", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let duration {
            Text("Done in \(duration)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(summary.costUSD.map { String(format: "Estimated API-equivalent cost: $%.4f (your plan covers this)", $0) } ?? "")
        }
    }

    private var duration: String? {
        guard let ms = summary.durationMs else { return nil }
        let seconds = max(1, Int(ms / 1000))
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

// MARK: - Composer

struct Composer: View {
    @Binding var text: String
    let isWorking: Bool
    let send: (String) -> Void
    let stop: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(isWorking ? "Send a follow-up…" : "Message Claude", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit(submit)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            if isWorking {
                Button("Stop", systemImage: "stop.fill", action: stop)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Interrupt Claude (⌘.)")
                    .keyboardShortcut(".", modifiers: .command)
            }
            Button("Send", systemImage: "arrow.up", action: submit)
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .readingColumn()
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .onAppear { focused = true }
    }

    private func submit() {
        let value = text
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = ""
        send(value)
    }
}

// MARK: - Terminal tab

/// Shown under the chat while the Terminal tab hosts this session.
private struct TerminalHostedNote: View {
    let phoneSync: Bool
    let show: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: phoneSync ? "iphone.radiowaves.left.and.right" : "terminal")
                .foregroundStyle(.secondary)
            Text(phoneSync
                 ? "Running in the Terminal tab with phone sync. Type there or in the Claude app on your phone; messages appear here as they're saved."
                 : "Running in the Terminal tab. Type there; messages appear here as they're saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show Terminal", action: show)
        }
        .padding(12)
    }
}

private struct TerminalTab: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let startPhoneSync: () -> Void

    private var terminal: TerminalSession? { model.terminals.session(for: conversation.id) }

    var body: some View {
        if conversation.isLive {
            ContentUnavailableView {
                Label("Session is running in Chat", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Opening it in the terminal at the same time would start a second Claude Code process on this session.")
            } actions: {
                Button("End chat process and open terminal") {
                    Task {
                        await model.sessions.stop(conversation)
                        for _ in 0..<40 where conversation.isLive { try? await Task.sleep(for: .milliseconds(100)) }
                        launch(remoteControl: false)
                    }
                }
            }
        } else if model.client.paths?.claude == nil {
            ContentUnavailableView("Claude Code CLI not found", systemImage: "terminal",
                                   description: Text("Install it with: curl -fsSL https://claude.ai/install.sh | bash"))
        } else if let terminal {
            VStack(spacing: 0) {
                statusBar(terminal)
                TerminalView(session: terminal)
                    .id(ObjectIdentifier(terminal))
            }
        } else {
            ContentUnavailableView {
                Label("Open in Claude Code", systemImage: "terminal")
            } description: {
                Text("Runs the real claude CLI on this session, for slash commands and anything the chat view doesn't cover. With phone sync, you can also keep going from the Claude app on your phone.")
            } actions: {
                Button("Open Terminal") { launch(remoteControl: false) }
                Button("Open with Phone Sync", systemImage: "iphone", action: startPhoneSync)
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func statusBar(_ terminal: TerminalSession) -> some View {
        HStack(spacing: 8) {
            if let code = terminal.exitCode {
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
                Text("claude exited\(code.map { " (code \($0))" } ?? "").")
                Spacer()
                Button("Restart") { launch(remoteControl: terminal.remoteControl) }
                Button("Close") { model.terminals.stop(conversation.id) }
            } else if terminal.remoteControl {
                Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.green)
                Text("Phone sync on. On your phone, open the Claude app, then Code. The first time, answer Claude Code's Remote Control prompt below.")
                Spacer()
                Button("Stop") { model.terminals.stop(conversation.id) }
            } else {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("Running claude in \(conversation.projectName).")
                Spacer()
                Button("Stop") { model.terminals.stop(conversation.id) }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func launch(remoteControl: Bool) {
        model.openTerminal(for: conversation, remoteControl: remoteControl)
    }
}
