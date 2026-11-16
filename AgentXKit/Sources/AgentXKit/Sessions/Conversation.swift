import Foundation
import Observation

/// Coding sessions live in a project folder; assistant conversations run in
/// AgentX's own folder with the Mac tools.
public enum ConversationKind: String, Sendable {
    case coding, assistant
}

/// Where assistant conversations run (kept out of the coding Sessions list).
public enum AssistantWorkspace {
    public static let path: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentX/Assistant").path

    static func prepare() {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Extra instructions for the assistant, on top of Claude Code's own.
    static func instructions(machine: MachineInfo) -> String {
        """
        You are the AgentX assistant, running on the user's Mac (\(machine.chip), \(machine.osVersion)). Their time zone is \(TimeZone.current.identifier).
        - Use the agentx tools (mcp__agentx__*) for Calendar, Reminders, files, apps, Shortcuts, appearance and volume, the clipboard, Mail, Notes and Messages. Prefer them to shell commands.
        - Pass dates to tools as local time in ISO 8601, like 2026-11-17T15:00.
        - Some tools need the user's OK. AgentX shows them an approval card when you call one, so call the tool instead of asking for permission in text first.
        - Only send email or messages when the user clearly asked you to send; otherwise make a draft.
        - Keep replies short and conversational. They often appear in a small launcher window.
        """
    }
}

/// One conversation in the UI: an existing session's history, plus anything
/// that happens live while AgentX drives it.
@MainActor
@Observable
public final class Conversation: Identifiable {
    /// Stable key: the session id for existing sessions, "new-<uuid>" for new ones.
    public let id: String
    public let kind: ConversationKind
    public var sessionId: String?
    public var cwd: String
    public var title: String
    public var gitBranch: String?
    /// When the session file was last written (used to warn about sessions
    /// that may still be open in another app).
    public var lastModified: Date?

    public private(set) var transcript = TranscriptBuilder()
    /// Text streaming in right now, before the full message arrives.
    public var draftText = ""
    public var draftThinking = ""

    public var liveHandle: String?
    public var liveState: LiveState?
    public var model: String?
    public var permissionMode: PermissionModeOption = .default

    /// Set when this conversation is an unattended automation run.
    public var automationRunID: UUID?
    /// Extra system-prompt text for this conversation (automation runs).
    var extraInstructions: String?
    /// Extra Claude Code permission rules (automation runs).
    var extraAllowedTools: [String] = []

    public var isLoadingHistory = false
    public var historyLoaded = false

    /// Streaming text arrives a few characters at a time; it's published about
    /// 25 times a second instead of on every delta.
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var pendingThinking = ""
    @ObservationIgnored private var flushScheduled = false
    /// Messages loaded from disk, so a reload can fetch only what's new.
    @ObservationIgnored var historyCount = 0
    @ObservationIgnored var lastHistoryUUID: String?
    /// Live items were added since the last load (a reload then has to be full).
    @ObservationIgnored var hasLiveItems = false
    /// When this conversation was last shown (old transcripts are unloaded).
    @ObservationIgnored var lastViewed = Date()
    public var error: String?

    public var items: [TranscriptItem] { transcript.items }

    /// Claude's latest reply text (an automation run's summary).
    public var lastAssistantText: String? {
        for item in items.reversed() {
            if case .assistant(let text) = item.kind, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }
    public var isLive: Bool { liveHandle != nil }
    public var isWorking: Bool { liveState == .running || liveState == .starting || liveState == .waiting }
    public var projectName: String { (cwd as NSString).lastPathComponent }

    init(id: String, kind: ConversationKind = .coding, sessionId: String?, cwd: String, title: String) {
        self.id = id
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
    }

    func loadHistory(_ messages: [JSONValue]) {
        var builder = TranscriptBuilder()
        for m in messages { builder.add(m) }
        // Keep anything that arrived live while history was loading.
        for item in transcript.items { builder.appendExisting(item) }
        hasLiveItems = !transcript.items.isEmpty
        transcript = builder
        rememberHistory(messages, count: messages.count)
        historyLoaded = true
    }

    /// Append messages that follow what's already loaded from disk.
    func appendHistory(_ messages: [JSONValue]) {
        guard !messages.isEmpty else { return }
        for m in messages { transcript.add(m) }
        rememberHistory(messages, count: historyCount + messages.count)
    }

    private func rememberHistory(_ messages: [JSONValue], count: Int) {
        historyCount = count
        if let uuid = messages.last?["uuid"]?.string { lastHistoryUUID = uuid }
    }

    /// Free the transcript (it's reloaded from disk when shown again).
    func unload() {
        transcript = TranscriptBuilder()
        historyLoaded = false
        historyCount = 0
        lastHistoryUUID = nil
        hasLiveItems = false
    }

    /// Replace the transcript with the session's newest main line from disk.
    func replaceHistory(_ messages: [JSONValue]) {
        var builder = TranscriptBuilder()
        for m in messages { builder.add(m) }
        transcript = builder
        clearDraft()
        hasLiveItems = false
        historyCount = 0
        lastHistoryUUID = nil
        rememberHistory(messages, count: messages.count)
        historyLoaded = true
    }

    func addLocalPrompt(_ text: String) {
        transcript.addLocalUserText(text)
        hasLiveItems = true
    }

    func addNotice(_ text: String, isError: Bool = false) {
        transcript.addNotice(text, isError: isError)
        hasLiveItems = true
    }

    private func clearDraft() {
        pendingText = ""
        pendingThinking = ""
        draftText = ""
        draftThinking = ""
    }

    private func scheduleDraftFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            self?.flushDraft()
        }
    }

    private func flushDraft() {
        flushScheduled = false
        if !pendingText.isEmpty { draftText += pendingText; pendingText = "" }
        if !pendingThinking.isEmpty { draftThinking += pendingThinking; pendingThinking = "" }
    }

    /// Apply one live SDK message.
    func apply(_ message: JSONValue) {
        switch message["type"]?.string {
        case "stream_event":
            guard message["parent_tool_use_id"]?.isNull ?? true, let event = message["event"] else { return }
            switch event["type"]?.string {
            case "message_start":
                clearDraft()
            case "content_block_delta":
                let delta = event["delta"]
                if let t = delta?["text"]?.string { pendingText += t }
                if let t = delta?["thinking"]?.string { pendingThinking += t }
                scheduleDraftFlush()
            default:
                break
            }
        case "assistant":
            clearDraft()
            transcript.add(message, live: true)
            hasLiveItems = true
        case "user", "system":
            transcript.add(message, live: true)
            hasLiveItems = true
        case "result":
            clearDraft()
            transcript.add(message, live: true)
            hasLiveItems = true
        default:
            break
        }
    }
}

extension TranscriptBuilder {
    mutating func appendExisting(_ item: TranscriptItem) {
        switch item.kind {
        case .user(let text): addLocalUserText(text)
        case .notice(let text, let isError): addNotice(text, isError: isError)
        default: break
        }
    }
}
