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
    public let receivedAt = Date()

    public var headline: String { title ?? "Claude wants to use \(toolName)" }
}

public enum ApprovalAnswer: Sendable {
    case allow
    case allowAlways
    case deny(String? = nil)

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
    /// Selected row in the Sessions list (a conversation id or session id).
    public var selectedKey: String?

    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private var approvalWaiters: [String: CheckedContinuation<JSONValue, Never>] = [:]
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored var onApprovalRequested: ((ApprovalRequest) -> Void)?

    init(client: AgentClient) {
        self.client = client
    }

    // MARK: Derived

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
        guard let key, conversations[key] == nil, conversation(forSessionId: key) == nil,
              let summary = sessions.first(where: { $0.sessionId == key }) else { return }
        open(summary)
    }

    public func approvals(for conversation: Conversation) -> [ApprovalRequest] {
        guard let handle = conversation.liveHandle else { return [] }
        return approvals.filter { $0.handle == handle }
    }

    /// Distinct project folders seen in history, most recent first.
    public var recentProjects: [String] {
        var seen = Set<String>()
        return sessions.compactMap(\.cwd).filter { seen.insert($0).inserted }
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
    }

    // MARK: Opening & starting

    /// Open an existing session (loads its history the first time).
    @discardableResult
    public func open(_ summary: SessionSummary) -> Conversation {
        if let existing = conversations[summary.sessionId] ?? conversation(forSessionId: summary.sessionId) {
            return existing
        }
        let c = Conversation(id: summary.sessionId, sessionId: summary.sessionId, cwd: summary.cwd ?? NSHomeDirectory(), title: summary.title)
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
            let messages = try await client.call("sessions.messages", ["sessionId": .string(sessionId), "dir": .string(c.cwd)], as: [JSONValue].self)
            c.loadHistory(messages)
        } catch {
            c.error = "Couldn't load history: \(error.localizedDescription)"
        }
    }

    /// Start a brand-new session in `cwd`.
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

    /// Send a message. Starts (or resumes) a live Claude Code process if needed.
    public func send(_ text: String, in c: Conversation) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        c.addLocalPrompt(text)
        c.error = nil
        do {
            if let handle = c.liveHandle {
                try await client.call("session.send", ["handle": .string(handle), "text": .string(text)])
                c.liveState = .running
            } else {
                c.liveState = .starting
                let result = try await client.call("session.start", [
                    "cwd": .string(c.cwd),
                    "prompt": .string(text),
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

    public func answer(_ approval: ApprovalRequest, _ answer: ApprovalAnswer) {
        approvals.removeAll { $0.id == approval.id }
        approvalWaiters.removeValue(forKey: approval.id)?.resume(returning: answer.json)
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
            let request = ApprovalRequest(
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
            return await withCheckedContinuation { cont in
                approvalWaiters[idString] = cont
                approvals.append(request)
                onApprovalRequested?(request)
            }
        default:
            throw AgentError.remote("AgentX doesn't handle \(method) yet.")
        }
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
            if state == .idle { scheduleRefresh(after: .milliseconds(500)) }

        case "session.event":
            guard let message = params["message"] else { return }
            if message["type"]?.string == "rate_limit_event", let info = message["rate_limit_info"].flatMap(RateLimitInfo.init) {
                latestRateLimit = info
            }
            conversation(forHandle: handle)?.apply(message)

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
