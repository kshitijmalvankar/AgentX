import AppKit
import Foundation
import Observation

public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard, chats, sessions, github, assistant, system, automations

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .chats: "Chats"
        case .sessions: "Sessions"
        case .github: "GitHub"
        case .assistant: "Assistant"
        case .system: "System"
        case .automations: "Automations"
        }
    }

    public var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .chats: "bubble.left.and.bubble.right"
        case .sessions: "terminal"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .assistant: "sparkles"
        case .system: "gauge.with.dots.needle.50percent"
        case .automations: "clock.arrow.2.circlepath"
        }
    }
}

/// The app's root state, shared by the main window, the menu bar and Settings.
@MainActor
@Observable
public final class AppModel {
    public static let shared = AppModel()

    public let client = AgentClient()
    public let sessions: SessionStore
    /// Terminal tab processes (kept alive across tab and session switches).
    public let terminals = TerminalStore()
    /// The Mac's vitals (sampled only while something shows them).
    public let system = SystemMonitor()
    /// Your GitHub profile, contributions and repos (through the gh CLI).
    public let github = GitHubStore()
    /// Scheduled Claude tasks.
    public let automations = AutomationCenter()
    /// Your Claude plan's usage (session and weekly limits).
    public let usage: UsageStore
    /// Folder to preselect the next time the New Session sheet opens.
    public var pendingNewSessionFolder: String?

    public var sidebar: SidebarItem? = .dashboard
    public private(set) var account: AccountSnapshot?
    public private(set) var accountError: String?
    public private(set) var isLoadingAccount = false
    /// Show the "New session" sheet (set from menus and the menu bar).
    public var showNewSession = false
    /// Show the sign-in terminal sheet.
    public var showLogin = false

    @ObservationIgnored private var bootstrapped = false
    /// Keeps the desktop widgets' data fresh.
    @ObservationIgnored private var widgetWriter: WidgetSnapshotWriter?
    /// Opens the main window; set by a SwiftUI view that has `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Bring up the main window (from the launcher or menu bar).
    public func showMainWindow() {
        openMainWindow?()
        NSApp.activate()
    }

    init() {
        sessions = SessionStore(client: client)
        usage = UsageStore(client: client)
        client.notificationHandler = { [weak self] method, params in
            self?.sessions.handleNotification(method, params: params)
            if method == "session.state" || method == "session.ended" { self?.widgetWriter?.setNeedsWrite() }
        }
        client.requestHandler = { [weak self] method, params, id in
            guard let self else { throw AgentError.notRunning("App is shutting down.") }
            if method == "tool.invoke" {
                return await MacToolbox.invoke(name: params["name"]?.string ?? "", arguments: params["args"] ?? [:])
            }
            return try await self.sessions.handleRequest(method, params: params, id: id)
        }
        sessions.assistantInstructions = AssistantWorkspace.instructions(machine: system.machine)
        github.context = { [weak self] in (self?.client.paths?.shellPath, self?.sessions.recentProjects ?? []) }
        automations.sessions = sessions
        automations.planUsage = { [weak self] in self?.usage.usage?.highest }
        sessions.onTurnFinished = { [weak self] c, result in
            self?.automations.turnFinished(c, result: result)
            self?.usage.refreshSoon()
        }
        sessions.onApprovalTimedOut = { [weak self] c in self?.automations.approvalUnanswered(c) }
        sessions.onApprovalRequested = { [weak self] request in
            NotificationManager.shared.postApproval(request)
            self?.widgetWriter?.setNeedsWrite()
        }
        usage.onUpdate = { [weak self] in self?.widgetWriter?.setNeedsWrite() }
        github.onUpdate = { [weak self] in self?.widgetWriter?.setNeedsWrite() }
        automations.onChange = { [weak self] in self?.widgetWriter?.setNeedsWrite() }
    }

    /// Start the agent engine and load everything. Safe to call more than once.
    public func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        NotificationManager.shared.configure(store: sessions)
        AssistantWorkspace.prepare()
        await client.start()
        await client.waitUntilReady()
        guard client.status == .ready else { return }
        // These are independent: run them side by side.
        sessions.startWatching()
        async let tools: Void = registerMacTools()
        async let list: Void = sessions.refresh()
        async let acct: Void = reloadAccount()   // also brings the first usage reading
        _ = await (tools, list, acct)
        usage.start()
        automations.start()
        let writer = WidgetSnapshotWriter(model: self)
        widgetWriter = writer
        writer.start()
    }

    public func restartEngine() async {
        await client.restart()
        await client.waitUntilReady()
        await registerMacTools()
        await sessions.refresh()
        await reloadAccount()
    }

    /// Tell agent-core which Mac tools exist (defined in Swift, run in Swift).
    private func registerMacTools() async {
        _ = try? await client.call("tools.register", ["tools": MacToolbox.definitions])
    }

    /// Ask the assistant something (Assistant section and launcher).
    @discardableResult
    public func askAssistant(_ prompt: String, in conversation: Conversation? = nil) async -> Conversation {
        if let conversation {
            await sessions.send(prompt, in: conversation)
            return conversation
        }
        return await sessions.startAssistant(prompt: prompt)
    }

    public func reloadAccount() async {
        isLoadingAccount = true
        defer { isLoadingAccount = false }
        do {
            // One short-lived Claude Code process gives both the account and plan usage.
            let snapshot = try await client.call("account.snapshot")
            account = try snapshot.decode(AccountSnapshot.self)
            usage.apply(snapshot["usage"] ?? .null)
            accountError = nil
        } catch {
            accountError = error.localizedDescription
        }
    }

    public var models: [ModelInfo] { account?.models ?? [] }

    /// Environment for processes we launch in the Terminal tab.
    public var terminalEnvironment: [String: String] {
        var env = ToolLocator.baseEnvironment()
        env["PATH"] = client.paths?.shellPath ?? env["PATH"]
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }

    /// Run the real `claude` CLI on a conversation in its Terminal tab,
    /// optionally with Remote Control so it continues from the Claude phone app.
    public func openTerminal(for c: Conversation, remoteControl: Bool) {
        guard let claude = client.paths?.claude else { return }
        var args = c.sessionId.map { ["--resume", $0] } ?? []
        if remoteControl { args += ["--remote-control", String(c.title.prefix(50))] }
        terminals.start(id: c.id, executable: claude, arguments: args, directory: c.cwd,
                        environment: terminalEnvironment, remoteControl: remoteControl)
    }

    /// Start a Claude Code session in your home folder that explains the
    /// current System snapshot. Claude asks before running any command.
    public func askClaudeAboutSystem() {
        guard let snapshot = system.latest else { return }
        let prompt = """
        Here's a snapshot of my Mac right now, from AgentX's System dashboard:

        \(snapshot.report(machine: system.machine))

        What's using the most resources, and does anything look wrong or worth fixing? You can run read-only commands (ps, top -l 1, vm_stat, df -h, pmset -g batt) to look closer. Don't quit apps, delete files or change settings without asking me first.
        """
        sidebar = .sessions
        Task { await sessions.startNew(cwd: NSHomeDirectory(), prompt: prompt, model: nil, mode: .default) }
    }

    /// Show Chats and start a new conversation on claude.ai.
    public func startNewChat() {
        sidebar = .chats
        ClaudeWebController.shared.startNewChat()
    }

    /// agentx://dashboard, agentx://system, agentx://github, … (from widgets).
    public func handle(_ url: URL) {
        guard url.scheme == "agentx", let host = url.host else { return }
        if let item = SidebarItem(rawValue: host) { sidebar = item }
    }

    public func openSession(_ key: String) {
        let c = sessions.conversations[key] ?? sessions.conversations.values.first { $0.sessionId == key }
        if c?.kind == .assistant || sessions.assistantSessions.contains(where: { $0.sessionId == key }) {
            sidebar = .assistant
            sessions.selectAssistant(key)
        } else {
            sidebar = .sessions
            sessions.select(key)
        }
    }
}
