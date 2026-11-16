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
        .navigationTitle(conversation.title)
        .navigationSubtitle(conversation.cwd.abbreviatingHome)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(conversation.projectName, systemImage: "folder")
                    if let branch = conversation.gitBranch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if let state = conversation.liveState { StateBadge(state: state) }

            Menu {
                Button("Default model") { Task { await store.setModel(nil, for: conversation) } }
                Divider()
                ForEach(model.models) { m in
                    Button(m.displayName) { Task { await store.setModel(m.value, for: conversation) } }
                }
            } label: {
                Label(modelLabel, systemImage: "cpu")
            }
            .fixedSize()
            .help("Model for this session")

            Menu {
                ForEach(PermissionModeOption.allCases) { mode in
                    Button { Task { await store.setPermissionMode(mode, for: conversation) } } label: {
                        if mode == conversation.permissionMode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                    }
                }
            } label: {
                Label("Permissions", systemImage: "lock.shield")
            }
            .fixedSize()
            .help(conversation.permissionMode.label)

            Button {
                if phoneSyncOn { tab = .terminal } else { startPhoneSync() }
            } label: {
                Label(phoneSyncOn ? "On your phone" : "Continue on phone", systemImage: phoneSyncOn ? "iphone.radiowaves.left.and.right" : "iphone")
            }
            .fixedSize()
            .help(phoneSyncOn ? "Phone sync is on: open the Claude app on your phone, then Code." : "Run this session with Remote Control so you can keep going from the Claude app on your phone.")

            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if conversation.isLive {
                Button("End", systemImage: "stop.circle") { Task { await store.stop(conversation) } }
                    .help("Stop the Claude Code process for this session. History is kept.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            .padding(.horizontal, 16)
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
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.isLoadingHistory && conversation.items.isEmpty {
                        ProgressView("Loading history…").frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if let error = conversation.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                    ForEach(conversation.items) { item in
                        TranscriptRow(item: item, cwd: conversation.cwd)
                    }
                    if !conversation.draftThinking.isEmpty && conversation.draftText.isEmpty {
                        Label("Thinking…", systemImage: "brain")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !conversation.draftText.isEmpty {
                        Text(conversation.draftText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if conversation.liveState == .running || conversation.liveState == .starting {
                        ProgressView().controlSize(.small)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.draftText.count / 200) { proxy.scrollTo("bottom", anchor: .bottom) }
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
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: 14))
            }
        case .assistant(let text):
            MarkdownText(text: text)
        case .thinking(let text):
            DisclosureGroup {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Thinking", systemImage: "brain").font(.callout).foregroundStyle(.secondary)
            }
        case .tool(let call):
            ToolCallCard(call: call, cwd: cwd)
        case .notice(let text, let isError):
            Text(text)
                .font(.caption)
                .foregroundStyle(isError ? .red : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
        case .result(let summary):
            ResultFooter(summary: summary)
        }
    }
}

private struct ResultFooter: View {
    let summary: RunSummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: summary.isError ? "xmark.octagon" : "checkmark.seal")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(summary.isError ? .red : .secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .help(summary.costUSD.map { String(format: "Estimated API-equivalent cost: $%.4f (your plan covers this)", $0) } ?? "")
    }

    private var text: String {
        var parts: [String] = [summary.isError ? "Stopped: \(summary.subtype.replacingOccurrences(of: "_", with: " "))" : "Done"]
        if let ms = summary.durationMs {
            let seconds = Int(ms / 1000)
            parts.append(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")
        }
        if let turns = summary.turns { parts.append("\(turns) turn\(turns == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
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
            TextField(isWorking ? "Send a follow-up (Claude will see it after this step)…" : "Message Claude…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit(submit)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            if isWorking {
                Button("Stop", systemImage: "stop.fill", action: stop)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Interrupt Claude")
                    .keyboardShortcut(".", modifiers: .command)
            }
            Button("Send", systemImage: "arrow.up", action: submit)
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
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
