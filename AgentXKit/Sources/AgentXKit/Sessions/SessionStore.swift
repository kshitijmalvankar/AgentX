import Foundation
import Observation

/// A tool call waiting for the user's OK.
public struct ApprovalRequest: Identifiable, Sendable {
    public let id: String
    let rpcID: JSONValue
    public let handle: String
    public let sessionId: String?
    public let cwd: String?
    public let toolName: String
    public let input: JSONValue
    public let title: String?
    public let displayName: String?
    public let detail: String?
    public let decisionReason: String?
    public let blockedPath: String?
    public let canAlwaysAllow: Bool
    public let defaultToNo: Bool
    /// The automation this came from, if it's an unattended run.
    public var automationName: String?
    /// Why AgentX's security policy asked (e.g. the conversation read a web page), if it did.
    public var policyReason: String?
    /// What untrusted content the conversation has read, if any.
    public var taint: String?
    /// Risky actions this conversation asked for in the last 10 minutes (including this one).
    public var recentRiskyActions = 0
    public var unattended = false
    public let receivedAt = Date()

    public var headline: String { title ?? "Claude wants to use \(toolName)" }
}

public enum ApprovalAnswer: Sendable {
    case allow
    case allowAlways
    case deny(String? = nil)

    var logLabel: String {
        switch self {
        case .allow: "allowed"
        case .allowAlways: "always allowed"
        case .deny: "denied"
        }
    }

    var json: JSONValue {
        switch self {
        case .allow: ["behavior": "allow"]
        case .allowAlways: ["behavior": "allowAlways"]
        case .deny(let message): ["behavior": "deny", "message": .optional(message)]
        }
    }
}

/// Everything about Claude Code sessions: the list on disk, the
/// conversations open in AgentX, and pending approvals.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var isRefreshing = false
    public private(set) var refreshError: String?
    public private(set) var conversations: [String: Conversation] = [:]
    public private(set) var approvals: [ApprovalRequest] = []
    public private(set) var latestRateLimit: RateLimitInfo?
    /// sessionId → Claude Code processes outside AgentX that have it open.
    public private(set) var externalOwners: [String: [ExternalSession]] = [:]
    /// Selected row in the Sessions list (a conversation id or session id).
    public var selectedKey: String?
    /// Selected conversation in the Assistant section.
    public var assistantSelectedKey: String?
    /// Extra instructions for assistant conversations (set by AppModel).
    @ObservationIgnored var assistantInstructions = ""
    /// AgentX's memory notes, added for assistant conversations when a process starts (nil: none or paused).
    @ObservationIgnored var memoryPrompt: @MainActor () -> String? = { nil }

    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private var approvalWaiters: [String: CheckedContinuation<JSONValue, Never>] = [:]
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var registryWatcher: DirectoryWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Conversation id → timer that closes its idle Claude Code process.
    @ObservationIgnored private var idleTimers: [String: Task<Void, Never>] = [:]
    /// An idle Claude Code process (~300 MB) is closed after this long; the
    /// next message resumes the session.
    @ObservationIgnored var idleProcessTimeout: Duration = .seconds(600)
    /// How many non-running transcripts stay loaded in memory.
    static let loadedTranscriptLimit = 6
    @ObservationIgnored var onApprovalRequested: ((ApprovalRequest) -> Void)?
    /// A Claude Code turn ended (`result` message): used to finish automation runs.
    @ObservationIgnored var onTurnFinished: ((Conversation, JSONValue) -> Void)?
    /// An unattended run's approval went unanswered and was denied.
    @ObservationIgnored var onApprovalTimedOut: ((Conversation) -> Void)?
    /// How long an unattended run waits for an approval before denying it.
    @ObservationIgnored var unattendedApprovalTimeout: Duration = .seconds(600)
    /// An approval was answered (by you, a notification or a timeout): for the activity log.
    @ObservationIgnored var onApprovalAnswered: ((ApprovalRequest, ApprovalAnswer) -> Void)?
    /// Set when sessions mustn't start (e.g. the Claude Code binary failed its signature check).
    public var startBlockedReason: String?

    init(client: AgentClient) {
        self.client = client
    }

    // MARK: Derived

    /// Claude Code sessions in your projects (assistant conversations excluded).
    public var codingSessions: [SessionSummary] { sessions.filter { $0.cwd != AssistantWorkspace.path } }

    /// Past assistant conversations, newest first.
    public var assistantSessions: [SessionSummary] { sessions.filter { $0.cwd == AssistantWorkspace.path } }

    public var selectedAssistantConversation: Conversation? {
        guard let key = assistantSelectedKey else { return nil }
        return conversations[key] ?? conversation(forSessionId: key)
    }

    public func selectAssistant(_ key: String?) {
        assistantSelectedKey = key
        show(key)
    }

    public var liveConversations: [Conversation] {
        conversations.values.filter(\.isLive).sorted { $0.title < $1.title }
    }

    public var selectedConversation: Conversation? {
        guard let key = selectedKey else { return nil }
        return conversations[key] ?? conversation(forSessionId: key)
    }

    /// Select a row; opens the session (and loads its history) if needed.
    public func select(_ key: String?) {
        selectedKey = key
        show(key)
    }

    /// Open (or reload) a conversation that's about to be shown, and unload old ones.
    private func show(_ key: String?) {
        guard let key else { return }
        if let existing = conversations[key] ?? conversation(forSessionId: key) {
            existing.lastViewed = Date()
            if !existing.historyLoaded, !existing.isLoadingHistory, existing.sessionId != nil {
                Task { await loadHistory(existing) }
            } else {
                reloadIfChangedElsewhere(existing)
            }
        } else if let summary = sessions.first(where: { $0.sessionId == key }) {
            open(summary)
        }
        unloadOldTranscripts()
    }

    /// Keep only the most recently viewed transcripts in memory.
    private func unloadOldTranscripts() {
        let shown = Set([selectedConversation?.id, selectedAssistantConversation?.id].compactMap { $0 })
        let candidates = conversations.values
            .filter { $0.historyLoaded && !$0.isLive && $0.automationRunID == nil && !shown.contains($0.id) && $0.sessionId != nil }
            .sorted { $0.lastViewed > $1.lastViewed }
        for c in candidates.dropFirst(Self.loadedTranscriptLimit) { c.unload() }
    }

    /// Close a live session's Claude Code process once it has sat idle for a while.
    private func scheduleIdleClose(_ c: Conversation) {
        idleTimers[c.id]?.cancel()
        let timeout = idleProcessTimeout
        idleTimers[c.id] = Task { [weak self, weak c] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let c, c.liveState == .idle, c.liveHandle != nil else { return }
            await self.stop(c)
        }
    }

    /// Other apps that have this conversation's session open right now.
    public func externalOwners(of conversation: Conversation) -> [ExternalSession] {
        conversation.sessionId.flatMap { externalOwners[$0] } ?? []
    }

    /// How many approvals are waiting in conversations of one kind (sidebar badges).
    public func approvalCount(kind: ConversationKind) -> Int {
        approvals.filter { conversation(forHandle: $0.handle)?.kind == kind }.count
    }

    public func approvals(for conversation: Conversation) -> [ApprovalRequest] {
        guard let handle = conversation.liveHandle else { return [] }
        return approvals.filter { $0.handle == handle }
    }

    /// Distinct project folders seen in history, most recent first.
    public var recentProjects: [String] {
        var seen = Set<String>()
        return codingSessions.compactMap(\.cwd).filter { seen.insert($0).inserted }
    }

    func conversation(forSessionId id: String) -> Conversation? {
        conversations.values.first { $0.sessionId == id }
    }

    private func conversation(forHandle handle: String) -> Conversation? {
        conversations.values.first { $0.liveHandle == handle }
    }

    // MARK: Session list

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            sessions = try await client.call("sessions.list", ["limit": 500], as: [SessionSummary].self)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
        refreshExternalOwners()
        if let selected = selectedConversation { reloadIfChangedElsewhere(selected) }
    }

    func refreshExternalOwners() {
        var ownParents: Set<Int32> = [getpid()]
        if let sidecar = client.sidecarPID { ownParents.insert(sidecar) }
        let owners = SessionRegistry.scan(ownParents: ownParents)
        if owners != externalOwners { externalOwners = owners }
    }

    /// If an idle conversation's session file has been written since we
    /// loaded it (Terminal, the Claude app, ...), show the newest version.
    private func reloadIfChangedElsewhere(_ c: Conversation) {
        guard !c.isLive, !c.isLoadingHistory, c.historyLoaded, let id = c.sessionId,
              let summary = sessions.first(where: { $0.sessionId == id }) else { return }
        guard let loaded = c.lastModified, summary.modifiedDate.timeIntervalSince(loaded) > 1 else { return }
        c.lastModified = summary.modifiedDate
        Task { await reloadHistory(c) }
    }

    /// Coalesce bursts of file changes into one refresh.
    func scheduleRefresh(after delay: Duration = .seconds(2)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func startWatching() {
        guard watcher == nil else { return }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
        let watcher = DirectoryWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watcher.start()
        self.watcher = watcher

        try? FileManager.default.createDirectory(at: SessionRegistry.directory, withIntermediateDirectories: true)
        let registryWatcher = DirectoryWatcher(path: SessionRegistry.directory.path, latency: 1) { [weak self] in
            Task { @MainActor in self?.refreshExternalOwners() }
        }
        registryWatcher.start()
        self.registryWatcher = registryWatcher
        refreshExternalOwners()
    }

    // MARK: Opening & starting

    /// Open an existing session (loads its history the first time).
    @discardableResult
    public func open(_ summary: SessionSummary) -> Conversation {
        if let existing = conversations[summary.sessionId] ?? conversation(forSessionId: summary.sessionId) {
            return existing
        }
        let kind: ConversationKind = summary.cwd == AssistantWorkspace.path ? .assistant : .coding
        let c = Conversation(id: summary.sessionId, kind: kind, sessionId: summary.sessionId, cwd: summary.cwd ?? NSHomeDirectory(), title: summary.title)
        c.gitBranch = summary.gitBranch
        c.lastModified = summary.modifiedDate
        conversations[c.id] = c
        Task { await loadHistory(c) }
        return c
    }

    public func loadHistory(_ c: Conversation) async {
        guard let sessionId = c.sessionId, !c.isLoadingHistory else { return }
        c.isLoadingHistory = true
        defer { c.isLoadingHistory = false }
        do {
            let messages = try await client.call("sessions.messages", ["sessionId": .string(sessionId), "dir": .string(c.cwd)]).array ?? []
            c.loadHistory(messages)
        } catch {
            c.error = "Couldn't load history: \(error.localizedDescription)"
        }
    }

    /// Bring the transcript up to the session's newest main line on disk.
    /// When nothing was added live, only the new messages are fetched (checked
    /// against the last one already loaded); otherwise it's a full reload.
    public func reloadHistory(_ c: Conversation) async {
        guard let sessionId = c.sessionId else { return }
        do {
            if !c.hasLiveItems, c.historyLoaded, c.historyCount > 0, let last = c.lastHistoryUUID {
                let tail = try await client.call("sessions.messages", [
                    "sessionId": .string(sessionId), "dir": .string(c.cwd), "offset": .number(Double(c.historyCount - 1)),
                ]).array ?? []
                if tail.first?["uuid"]?.string == last {
                    c.appendHistory(Array(tail.dropFirst()))
                    return
                }
            }
            let messages = try await client.call("sessions.messages", ["sessionId": .string(sessionId), "dir": .string(c.cwd)]).array ?? []
            c.replaceHistory(messages)
        } catch {
            c.error = "Couldn't reload history: \(error.localizedDescription)"
        }
    }

    /// Start a brand-new coding session in `cwd`.
    @discardableResult
    public func startNew(cwd: String, prompt: String, model: String?, mode: PermissionModeOption) async -> Conversation {
        let c = Conversation(id: "new-\(UUID().uuidString)", sessionId: nil, cwd: cwd, title: String(prompt.prefix(80)))
        c.model = model
        c.permissionMode = mode
        c.historyLoaded = true
        conversations[c.id] = c
        selectedKey = c.id
        await send(prompt, in: c)
        return c
    }

    /// Start an unattended automation run (assistant or coding).
    func startAutomationRun(kind: ConversationKind, cwd: String, prompt: String, title: String,
                            runID: UUID, instructions: String, allowedTools: [String]) async -> Conversation {
        if kind == .assistant { AssistantWorkspace.prepare() }
        let c = Conversation(id: "auto-\(UUID().uuidString)", kind: kind, sessionId: nil, cwd: cwd, title: title)
        c.automationRunID = runID
        c.taint = "it was started by a schedule or trigger, not by you"
        c.extraInstructions = instructions
        c.extraAllowedTools = allowedTools
        c.historyLoaded = true
        conversations[c.id] = c
        await send(prompt, in: c)
        return c
    }

    /// For tests and tools that build a conversation themselves.
    func insert(_ c: Conversation) { conversations[c.id] = c }

    /// Start a new assistant conversation (Mac tools on). `taint` starts it as
    /// having read untrusted content (e.g. text carried over from claude.ai).
    @discardableResult
    public func startAssistant(prompt: String, taint: String? = nil, images: [JSONValue] = []) async -> Conversation {
        AssistantWorkspace.prepare()
        let title = ScreenContext.displayText(prompt).replacingOccurrences(of: "\n\n(with what was on screen)", with: "")
        let c = Conversation(id: "new-\(UUID().uuidString)", kind: .assistant, sessionId: nil,
                             cwd: AssistantWorkspace.path, title: String(title.prefix(80)))
        c.taint = taint
        c.historyLoaded = true
        conversations[c.id] = c
        assistantSelectedKey = c.id
        await send(prompt, in: c, images: images, taint: taint)
        return c
    }

    /// Send a message. Starts (or resumes) a live Claude Code process if needed.
    ///
    /// AgentX always continues the session itself, never a fork, and always
    /// from its newest message, whichever app wrote it: an idle process that
    /// fell behind (another app continued the session) is restarted first.
    /// `images`: pictures sent with the message ({mediaType, data}). `taint`: the
    /// message carries untrusted content (what's on screen), so the conversation
    /// is guarded from here on.
    public func send(_ text: String, in c: Conversation, images: [JSONValue] = [], taint: String? = nil) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        c.error = nil
        if let taint, c.taint == nil { c.taint = taint }
        if let handle = c.liveHandle, c.liveState == .idle {
            let stale = (try? await client.call("session.isStale", ["handle": .string(handle)]))?["stale"]?.bool ?? false
            if stale {
                c.liveHandle = nil
                c.liveState = nil
                _ = try? await client.call("session.close", ["handle": .string(handle)])
                await reloadHistory(c)
                c.addNotice("Picked up newer messages from another app.")
            }
        } else if !c.isLive, c.sessionId != nil {
            await reloadHistory(c)
        }
        c.addLocalPrompt(images.isEmpty ? text : text + "\n\n(with a picture of the window)")
        do {
            if let handle = c.liveHandle {
                try await client.call("session.send", ["handle": .string(handle), "text": .string(text),
                                                       "images": .array(images), "taint": .optional(taint)])
                c.liveState = .running
            } else {
                await beforeStart?()
                if let blocked = startBlockedReason { throw AgentError.remote(blocked) }
                c.liveState = .starting
                let result = try await client.call("session.start", [
                    "kind": .string(c.kind.rawValue),
                    "unattended": .bool(c.automationRunID != nil),
                    // Keeps a conversation that already read untrusted content marked after its process restarts.
                    "taint": .optional(c.taint),
                    "appendSystemPrompt": systemPromptAddition(for: c),
                    "allowedTools": c.extraAllowedTools.isEmpty ? .null : .array(c.extraAllowedTools.map(JSONValue.string)),
                    "cwd": .string(c.cwd),
                    "prompt": .string(text),
                    "images": .array(images),
                    "resume": .optional(c.sessionId),
                    "model": .optional(c.model),
                    "permissionMode": .string(c.permissionMode.rawValue),
                ])
                c.liveHandle = result["handle"]?.string
                c.liveState = .running
            }
        } catch {
            c.liveState = c.liveHandle == nil ? nil : c.liveState
            c.error = error.localizedDescription
        }
    }

    private func systemPromptAddition(for c: Conversation) -> JSONValue {
        let parts = [c.kind == .assistant ? assistantInstructions : nil,
                     c.kind == .assistant ? memoryPrompt() : nil,
                     c.extraInstructions].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? .null : .string(parts.joined(separator: "\n\n"))
    }

    public func interrupt(_ c: Conversation) async {
        guard let handle = c.liveHandle else { return }
        do { try await client.call("session.interrupt", ["handle": .string(handle)]) } catch { c.error = error.localizedDescription }
    }

    /// Stop the Claude Code process for this conversation (history is kept).
    public func stop(_ c: Conversation) async {
        guard let handle = c.liveHandle else { return }
        _ = try? await client.call("session.close", ["handle": .string(handle)])
    }

    public func setModel(_ model: String?, for c: Conversation) async {
        c.model = model
        guard let handle = c.liveHandle else { return }
        do { try await client.call("session.setModel", ["handle": .string(handle), "model": .optional(model)]) } catch { c.error = error.localizedDescription }
    }

    public func setPermissionMode(_ mode: PermissionModeOption, for c: Conversation) async {
        c.permissionMode = mode
        guard let handle = c.liveHandle else { return }
        do { try await client.call("session.setPermissionMode", ["handle": .string(handle), "mode": .string(mode.rawValue)]) } catch { c.error = error.localizedDescription }
    }

    // MARK: Approvals

    /// Where Claude Code keeps transcripts (a temporary folder in tests).
    @ObservationIgnored var projectsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    /// How deleted conversations leave: to the Trash, so you can put them back.
    @ObservationIgnored var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Move a conversation to the Trash: its Claude Code transcript
    /// (`<session>.jsonl`) and helper folder (`<session>/`), the same files the
    /// Agent SDK's deleteSession removes, but recoverable. A running process is
    /// stopped first. A conversation that never got a session id just closes.
    func trash(_ key: String) async throws {
        let c = conversations[key] ?? conversation(forSessionId: key)
        let sessionId = c?.sessionId ?? (sessions.contains { $0.sessionId == key } ? key : nil)
        if let c, c.isLive {
            await stop(c)
            for _ in 0..<50 where c.isLive { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if let sessionId {
            let files = SessionFiles.locate(sessionId, in: projectsDirectory)
            guard !files.isEmpty else { throw ToolError("Couldn't find this conversation's files in ~/.claude/projects.") }
            for url in files { try moveToTrash(url) }
            sessions.removeAll { $0.sessionId == sessionId }
        }
        if let c { conversations.removeValue(forKey: c.id) }
        for k in [key, c?.id, sessionId].compactMap({ $0 }) {
            if assistantSelectedKey == k { assistantSelectedKey = nil }
            if selectedKey == k { selectedKey = nil }
        }
        scheduleRefresh(after: .milliseconds(500))
    }

    /// Awaited before a Claude Code process starts (the engine's signature check).
    @ObservationIgnored var beforeStart: (() async -> Void)?

    public func answer(_ approval: ApprovalRequest, _ answer: ApprovalAnswer) {
        guard approvals.contains(where: { $0.id == approval.id }) else { return }
        approvals.removeAll { $0.id == approval.id }
        approvalWaiters.removeValue(forKey: approval.id)?.resume(returning: answer.json)
        onApprovalAnswered?(approval, answer)
    }

    /// The conversation a sidecar handle belongs to: its title and session id (for the activity log).
    func origin(forHandle handle: String) -> (title: String, sessionId: String?)? {
        conversation(forHandle: handle).map { ($0.title, $0.sessionId) }
    }

    public func answer(approvalID: String, _ answer: ApprovalAnswer) {
        guard let approval = approvals.first(where: { $0.id == approvalID }) else { return }
        self.answer(approval, answer)
    }

    // MARK: Messages from agent-core

    func handleRequest(_ method: String, params: JSONValue, id: JSONValue) async throws -> JSONValue {
        switch method {
        case "permission.request":
            let idString = id.string ?? id.prettyPrinted()
            let owner = conversation(forHandle: params["handle"]?.string ?? "")
            var request = ApprovalRequest(
                id: idString,
                rpcID: id,
                handle: params["handle"]?.string ?? "",
                sessionId: params["sessionId"]?.string,
                cwd: params["cwd"]?.string,
                toolName: params["toolName"]?.string ?? "Tool",
                input: params["input"] ?? [:],
                title: params["title"]?.string,
                displayName: params["displayName"]?.string,
                detail: params["description"]?.string,
                decisionReason: params["decisionReason"]?.string,
                blockedPath: params["blockedPath"]?.string,
                canAlwaysAllow: params["canAlwaysAllow"]?.bool ?? false,
                defaultToNo: params["defaultToNo"]?.bool ?? false
            )
            request.policyReason = params["policyReason"]?.string
            request.taint = params["taint"]?.string
            request.recentRiskyActions = params["recentRiskyActions"]?.int ?? 0
            request.unattended = params["unattended"]?.bool ?? false
            if let owner, owner.automationRunID != nil {
                request.automationName = owner.title
                // Nobody may be watching: deny it if it isn't answered in time.
                let timeout = unattendedApprovalTimeout
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard let self, self.approvals.contains(where: { $0.id == idString }) else { return }
                    self.answer(approvalID: idString, .deny("No answer within \(Self.describe(timeout)); skipped while the user was away."))
                    self.onApprovalTimedOut?(owner)
                }
            }
            return await withCheckedContinuation { cont in
                approvalWaiters[idString] = cont
                approvals.append(request)
                onApprovalRequested?(request)
            }
        default:
            throw AgentError.remote("AgentX doesn't handle \(method) yet.")
        }
    }

    private static func describe(_ d: Duration) -> String {
        let seconds = Int(d.components.seconds)
        return seconds >= 60 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
    }

    func handleNotification(_ method: String, params: JSONValue) {
        let handle = params["handle"]?.string ?? ""
        switch method {
        case "session.started":
            guard let c = conversation(forHandle: handle) else { return }
            c.sessionId = params["sessionId"]?.string ?? c.sessionId
            c.model = params["model"]?.string ?? c.model

        case "session.state":
            guard let c = conversation(forHandle: handle), let state = params["state"]?.string.flatMap(LiveState.init) else { return }
            c.liveState = state
            if state == .idle { scheduleIdleClose(c) } else { idleTimers.removeValue(forKey: c.id)?.cancel() }
            if state == .idle { scheduleRefresh(after: .milliseconds(500)) }

        case "session.event":
            guard let message = params["message"] else { return }
            if message["type"]?.string == "rate_limit_event", let info = message["rate_limit_info"].flatMap(RateLimitInfo.init) {
                latestRateLimit = info
            }
            if let c = conversation(forHandle: handle) {
                c.apply(message)
                if message["type"]?.string == "result" { onTurnFinished?(c, message) }
            }

        case "session.ended":
            if let c = conversation(forHandle: handle) {
                c.liveHandle = nil
                c.liveState = nil
                c.draftText = ""
                c.draftThinking = ""
                if let error = params["error"]?.string { c.addNotice(error, isError: true) }
            }
            cancelApprovals { $0.handle == handle }
            scheduleRefresh(after: .milliseconds(500))

        case "session.policy":
            guard let c = conversation(forHandle: handle) else { return }
            if let taint = params["taint"]?.string, c.taint == nil { c.taint = taint }
            if params["rateLimited"]?.bool == true {
                c.addNotice("AgentX stopped this run: it asked for too many risky actions in a short time. Look over what it did before running it again.", isError: true)
            }

        case "rpc.cancelled":
            let id = params["id"]?.string
            cancelApprovals { $0.id == id }

        case "core.exited":
            for c in conversations.values where c.isLive {
                c.liveHandle = nil
                c.liveState = nil
                c.addNotice("The agent engine stopped. Send a message to resume.", isError: true)
            }
            cancelApprovals { _ in true }

        default:
            break
        }
    }

    private func cancelApprovals(where predicate: (ApprovalRequest) -> Bool) {
        for approval in approvals where predicate(approval) {
            approvalWaiters.removeValue(forKey: approval.id)?.resume(returning: ApprovalAnswer.deny("Cancelled").json)
        }
        approvals.removeAll(where: predicate)
    }
}

/// Finding a session's files in ~/.claude/projects.
enum SessionFiles {
    /// `<project>/<id>.jsonl` and, if present, `<project>/<id>/`. Only real
    /// session ids, and only files that really are inside the projects folder.
    static func locate(_ sessionId: String, in projects: URL) -> [URL] {
        guard UUID(uuidString: sessionId) != nil else { return [] }
        let fm = FileManager.default
        let root = projects.resolvingSymlinksInPath().standardizedFileURL.path
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        for dir in dirs {
            let transcript = dir.appendingPathComponent("\(sessionId).jsonl")
            guard fm.fileExists(atPath: transcript.path) else { continue }
            let inside = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") }
            guard inside(transcript) else { return [] }
            var found = [transcript]
            let folder = dir.appendingPathComponent(sessionId, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue, inside(folder) { found.append(folder) }
            return found
        }
        return []
    }
}
