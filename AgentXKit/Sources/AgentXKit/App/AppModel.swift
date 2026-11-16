import Foundation
import Observation

public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard, sessions, assistant, system, automations

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .sessions: "Sessions"
        case .assistant: "Assistant"
        case .system: "System"
        case .automations: "Automations"
        }
    }

    public var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .sessions: "terminal"
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

    public var sidebar: SidebarItem? = .dashboard
    public private(set) var account: AccountSnapshot?
    public private(set) var accountError: String?
    public private(set) var isLoadingAccount = false
    /// Show the "New session" sheet (set from menus and the menu bar).
    public var showNewSession = false
    /// Show the sign-in terminal sheet.
    public var showLogin = false

    @ObservationIgnored private var bootstrapped = false

    init() {
        sessions = SessionStore(client: client)
        client.notificationHandler = { [weak self] method, params in
            self?.sessions.handleNotification(method, params: params)
        }
        client.requestHandler = { [weak self] method, params, id in
            guard let self else { throw AgentError.notRunning("App is shutting down.") }
            return try await self.sessions.handleRequest(method, params: params, id: id)
        }
        sessions.onApprovalRequested = { request in
            NotificationManager.shared.postApproval(request)
        }
    }

    /// Start the agent engine and load everything. Safe to call more than once.
    public func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        NotificationManager.shared.configure(store: sessions)
        await client.start()
        await client.waitUntilReady()
        guard client.status == .ready else { return }
        sessions.startWatching()
        async let list: Void = sessions.refresh()
        async let acct: Void = reloadAccount()
        _ = await (list, acct)
    }

    public func restartEngine() async {
        await client.restart()
        await client.waitUntilReady()
        await sessions.refresh()
        await reloadAccount()
    }

    public func reloadAccount() async {
        isLoadingAccount = true
        defer { isLoadingAccount = false }
        do {
            account = try await client.call("account.info", as: AccountSnapshot.self)
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

    public func openSession(_ key: String) {
        sidebar = .sessions
        sessions.select(key)
    }
}
