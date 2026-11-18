import AppKit
import Foundation
import Observation

public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard, chats, sessions, github, system, automations

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .chats: "Chats"
        case .sessions: "Sessions"
        case .github: "GitHub"
        case .system: "System"
        case .automations: "Automations"
        }
    }

    public var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .chats: "bubble.left.and.text.bubble.right"
        case .sessions: "terminal"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .system: "gauge.with.dots.needle.50percent"
        case .automations: "clock.arrow.2.circlepath"
        }
    }
}

/// The two sides of the Chats section.
public enum ClaudeMode: String, CaseIterable, Identifiable, Sendable {
    /// Claude Code on this Mac, with AgentX's Mac tools (the assistant).
    case mac
    /// claude.ai, the same chats as the Claude app on your phone.
    case web

    public var id: String { rawValue }
    public var title: String { self == .mac ? "On this Mac" : "claude.ai" }
    public var symbol: String { self == .mac ? "desktopcomputer" : "cloud" }
    public var explanation: String {
        self == .mac
            ? "Can act on your Mac: Calendar, Reminders, files, apps, settings, Mail, Notes and Messages."
            : "Your claude.ai chats, synced with the Claude app on your phone. Can't act on your Mac."
    }
}

/// Text carried from a claude.ai chat into a new conversation on this Mac.
public struct MacHandoff: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    /// Why the new conversation starts as having read untrusted content.
    public let taint: String
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
    /// What Claude and AgentX did that changed something, and every security decision.
    public let activity: ActivityLog
    /// Today's events and reminders (the dashboard's Today card).
    public let today = TodayAgenda()
    /// The encrypted link to the AgentX iPhone app (Settings → iPhone).
    public let phone: PhoneLink
    /// What AgentX remembers about you (Settings → Memory).
    public let memory = MemoryStore.shared
    /// Anthropic's signature on the Claude Code engine binary (nil while checking).
    public private(set) var engineSignature: CodeSignature.Status?
    /// Folder to preselect the next time the New Session sheet opens.
    public var pendingNewSessionFolder: String?

    public var sidebar: SidebarItem? = .dashboard
    /// Which side of the Chats section is showing (remembered between launches).
    public var claudeMode: ClaudeMode = ClaudeMode(rawValue: UserDefaults.standard.string(forKey: "claudeMode") ?? "") ?? .mac {
        didSet { UserDefaults.standard.set(claudeMode.rawValue, forKey: "claudeMode") }
    }
    /// Text waiting in a new Mac conversation's composer (from "Continue on Mac").
    public var macHandoff: MacHandoff?
    /// Set after "Continue in claude.ai" copied a conversation, so the web side can say "paste it".
    public var webPasteHint = false
    public private(set) var account: AccountSnapshot?
    public private(set) var accountError: String?
    public private(set) var isLoadingAccount = false
    /// Show the "New session" sheet (set from menus and the menu bar).
    public var showNewSession = false
    /// Show the sign-in terminal sheet.
    public var showLogin = false

    @ObservationIgnored private var bootstrapped = false
    /// Finishes once the engine binary is verified and agent-core has the security settings.
    @ObservationIgnored private var securityReady: Task<Void, Never>?
    /// Keeps the desktop widgets' data fresh.
    @ObservationIgnored private var widgetWriter: WidgetSnapshotWriter?
    /// Opens the main window; set by a SwiftUI view that has `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Bring up the main window (from the launcher or menu bar).
    public func showMainWindow() {
        openMainWindow?()
        NSApp.activate()
    }

    /// Tests pass their own activity log and phone link (temporary files, no Keychain).
    init(activity: ActivityLog = ActivityLog(), phone: PhoneLink = PhoneLink()) {
        self.activity = activity
        self.phone = phone
        sessions = SessionStore(client: client)
        usage = UsageStore(client: client)
        client.notificationHandler = { [weak self] method, params in
            if method == "activity" { self?.recordActivity(params); return }
            self?.sessions.handleNotification(method, params: params)
            if method == "session.state" || method == "session.ended" { self?.widgetWriter?.setNeedsWrite() }
        }
        client.requestHandler = { [weak self] method, params, id in
            guard let self else { throw AgentError.notRunning("App is shutting down.") }
            if method == "tool.invoke" {
                let origin = self.sessions.origin(forHandle: params["handle"]?.string ?? "")?.title
                return await MacToolbox.invoke(name: params["name"]?.string ?? "", arguments: params["args"] ?? [:], origin: origin)
            }
            return try await self.sessions.handleRequest(method, params: params, id: id)
        }
        sessions.assistantInstructions = AssistantWorkspace.instructions(machine: system.machine)
        sessions.memoryPrompt = { MemoryStore.shared.promptSection() }
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
        sessions.onApprovalAnswered = { [weak self] request, answer in
            guard let self else { return }
            let origin = request.automationName ?? self.sessions.origin(forHandle: request.handle)?.title
            self.activity.record(.approval, answer.logLabel, tool: request.toolName,
                                 detail: ToolPresentation.summary(name: request.toolName, input: request.input, cwd: request.cwd),
                                 origin: origin, sessionId: request.sessionId)
        }
        sessions.onTrustTool = { [weak self] tool in
            guard let self else { return }
            SecuritySettings.trust(tool)
            self.activity.record(.policy, "trusted", tool: tool,
                                 detail: "\(SecuritySettings.displayName(ofTool: tool)) may run without asking, even after untrusted content.")
            Task { await self.sendSecuritySettings() }
        }
        sessions.beforeStart = { [weak self] in await self?.securityReady?.value }
        automations.onRunUpdate = { [weak self] run in
            let action = run.status == .running ? "started" : run.status.rawValue
            self?.activity.record(.automation, action, detail: run.summary ?? run.automationName, origin: run.automationName, sessionId: run.sessionId)
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
        memory.startWatching()
        FrontmostTracker.shared.start()
        SelectionBubble.shared.start()
        AppIndex.shared.refreshIfNeeded()
        await client.start()
        await client.waitUntilReady()
        guard client.status == .ready else { return }
        securityReady = Task { await configureSecurity() }
        // These are independent: run them side by side.
        sessions.startWatching()
        async let tools: Void = registerMacTools()
        async let list: Void = sessions.refresh()
        async let acct: Void = reloadAccount()   // also brings the first usage reading
        _ = await (tools, list, acct)
        usage.start()
        automations.start()
        phone.attach(self)
        let writer = WidgetSnapshotWriter(model: self)
        widgetWriter = writer
        writer.start()
    }

    public func restartEngine() async {
        await client.restart()
        await client.waitUntilReady()
        securityReady = Task { await configureSecurity() }
        await registerMacTools()
        await sessions.refresh()
        await reloadAccount()
    }

    /// Check the Claude Code engine's signature, then give agent-core the
    /// security settings: the verified binary, your path exceptions, and the
    /// project folders whose files don't count as untrusted.
    func configureSecurity() async {
        let claude = client.paths?.engineClaude
        let status: CodeSignature.Status = await Task.detached(priority: .userInitiated) {
            claude.map { CodeSignature.verify(path: $0) } ?? .missing
        }.value
        engineSignature = status
        switch status {
        case .verified:
            sessions.startBlockedReason = nil
        case .failed(let why):
            sessions.startBlockedReason = "AgentX won't start Claude: the Claude Code engine failed Anthropic's signature check (\(why)). Reinstall agent-core (npm ci in agent-core) and restart."
            activity.record(.policy, "blocked", tool: "claude", detail: "Engine signature check failed: \(why)")
        case .missing:
            sessions.startBlockedReason = "AgentX couldn't find the Claude Code engine inside agent-core. Run npm ci in agent-core and restart."
        }
        await sendSecuritySettings()
    }

    /// Push path exceptions and trusted folders to agent-core (also after you change them in Settings).
    func sendSecuritySettings() async {
        let claude = engineSignature?.isVerified == true ? client.paths?.engineClaude : nil
        let roots = SecuritySettings.trustedRoots(from: sessions.recentProjects, home: PathGuard.home)
        _ = try? await client.call("security.configure", [
            "pathExceptions": .array(PathGuard.exceptions.map(JSONValue.string)),
            "trustedRoots": .array(roots.map(JSONValue.string)),
            "claudePath": .optional(claude),
            "trustedTools": .array(SecuritySettings.trustedTools.map(JSONValue.string)),
            "trustConnectorReads": .bool(SecuritySettings.trustConnectorReads),
        ])
    }

    /// An "activity" notification from agent-core (a tool ran, or the policy acted).
    private func recordActivity(_ params: JSONValue) {
        let kind: ActivityEntry.Kind = params["kind"]?.string == "policy" ? .policy : .tool
        let origin = sessions.origin(forHandle: params["handle"]?.string ?? "")
        activity.record(kind, params["action"]?.string ?? "", tool: params["tool"]?.string,
                        detail: params["detail"]?.string ?? "", origin: origin?.title,
                        sessionId: params["sessionId"]?.string ?? origin?.sessionId)
    }

    /// The kill switch: interrupt and close every running Claude session, deny
    /// everything waiting for approval, and pause automations.
    public func stopEverything(source: String = "the menu bar") async {
        automations.isPaused = true
        automations.cancelActiveRuns(reason: "Stopped with Stop everything.")
        let pending = sessions.approvals
        for approval in pending { sessions.answer(approval, .deny("The user pressed Stop everything.")) }
        let live = sessions.liveConversations
        for c in live { await sessions.interrupt(c) }
        for c in live { await sessions.stop(c) }
        activity.record(.killSwitch, "stopped",
                        detail: "Stopped \(live.count) running conversation\(live.count == 1 ? "" : "s"), denied \(pending.count) approval\(pending.count == 1 ? "" : "s") and paused automations (from \(source)).")
        NotificationManager.shared.postNotice(title: "AgentX stopped everything",
                                              body: "Automations stay paused until you turn them back on in Automations.")
    }

    /// Tell agent-core which Mac tools exist (defined in Swift, run in Swift).
    private func registerMacTools() async {
        _ = try? await client.call("tools.register", ["tools": MacToolbox.definitions])
    }

    /// Ask the assistant something (the Mac side of Chats and the launcher).
    /// `taint` starts a new conversation as having read untrusted content.
    @discardableResult
    public func askAssistant(_ prompt: String, in conversation: Conversation? = nil, taint: String? = nil,
                             images: [JSONValue] = []) async -> Conversation {
        if let conversation {
            await sessions.send(prompt, in: conversation, images: images, taint: taint)
            return conversation
        }
        return await sessions.startAssistant(prompt: prompt, taint: taint, images: images)
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

    /// Show Chats and start a new chat on whichever side you used last.
    public func newChat() {
        sidebar = .chats
        switch claudeMode {
        case .mac: sessions.selectAssistant(nil)
        case .web: ClaudeWebController.shared.startNewChat()
        }
    }

    /// Show claude.ai and start a new chat there.
    public func startNewChat() {
        sidebar = .chats
        claudeMode = .web
        ClaudeWebController.shared.startNewChat()
    }

    /// Bring text from a claude.ai chat into a new conversation on this Mac.
    /// It lands in the composer (nothing is sent until you do), and the
    /// conversation starts as having read untrusted content: the chat may
    /// quote web pages or files.
    public func continueOnMac(_ text: String) {
        sidebar = .chats
        claudeMode = .mac
        sessions.selectAssistant(nil)
        macHandoff = MacHandoff(text: text, taint: "text carried over from claude.ai")
    }

    /// A conversation waiting for "Move to Trash?" (set from menus; Chats shows the dialog).
    public var pendingTrash: (key: String, title: String)?

    /// Move a Mac conversation to the Trash (after you confirmed).
    public func trashConversation(_ key: String, title: String) async {
        do {
            try await sessions.trash(key)
            activity.record(.tool, "moved to Trash", tool: "conversation", detail: title)
        } catch {
            activity.record(.tool, "couldn't move to Trash", tool: "conversation", detail: "\(title): \(error.localizedDescription)")
            NotificationManager.shared.postNotice(title: "Couldn't delete “\(title)”", body: error.localizedDescription)
        }
    }

    /// Copy a Mac conversation for pasting into a new claude.ai chat.
    public func continueInClaudeAI(_ c: Conversation) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.handoffMarkdown(for: c), forType: .string)
        startNewChat()
        webPasteHint = true
    }

    /// A conversation as plain Markdown: your messages and Claude's replies (no tool details).
    static func handoffMarkdown(for c: Conversation, limit: Int = 20_000) -> String {
        var parts: [String] = []
        for item in c.items {
            switch item.kind {
            case .user(let text): parts.append("**Me:** \(text)")
            case .assistant(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                parts.append("**Claude (on my Mac):** \(text)")
            default: break
            }
        }
        var body = parts.joined(separator: "\n\n")
        if body.count > limit { body = "…" + body.suffix(limit) }
        return "Continuing a conversation I had with Claude on my Mac (\(c.title)):\n\n\(body)\n\n"
    }

    /// agentx://dashboard, agentx://launcher?q=…, agentx://run/<id>?t=… (from
    /// widgets and controls). Links that do something need the route token.
    public func handle(_ url: URL) {
        switch URLRoute.parse(url, scheme: AppChannel.current.urlScheme, token: RouteToken.current()) {
        case .success(let route):
            perform(route)
        case .failure(.wrongScheme):
            return
        case .failure(let refusal):
            // Never log the query: it can hold the token or text.
            let why = refusal == .missingToken ? "it didn't carry AgentX's secret token" : "AgentX doesn't know it"
            activity.record(.link, "refused", detail: "Ignored a link to \(url.scheme ?? "")://\(url.host ?? "") because \(why).")
        }
    }

    func perform(_ route: URLRoute) {
        switch route {
        case .section(let item):
            sidebar = item
            showMainWindow()
        case .chats(let mode):
            sidebar = .chats
            claudeMode = mode
            showMainWindow()
        case .launcher(let prefill):
            LauncherController.shared.show(prefill: prefill)
        case .approvals:
            sidebar = .sessions
            showMainWindow()
        case .runAutomation(let id):
            guard let automation = automations.automations.first(where: { $0.id == id }) else { return }
            activity.record(.link, "ran", detail: "Started \(automation.name) from a link.", origin: automation.name)
            automations.runNow(automation)
        case .stopEverything:
            Task { await stopEverything(source: "a link") }
        }
    }

    public func openSession(_ key: String) {
        let c = sessions.conversations[key] ?? sessions.conversations.values.first { $0.sessionId == key }
        if c?.kind == .assistant || sessions.assistantSessions.contains(where: { $0.sessionId == key }) {
            sidebar = .chats
            claudeMode = .mac
            sessions.selectAssistant(key)
        } else {
            sidebar = .sessions
            sessions.select(key)
        }
    }
}
