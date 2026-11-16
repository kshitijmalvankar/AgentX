import Foundation
import Observation

/// One conversation in the UI: an existing session's history, plus anything
/// that happens live while AgentX drives it.
@MainActor
@Observable
public final class Conversation: Identifiable {
    /// Stable key: the session id for existing sessions, "new-<uuid>" for new ones.
    public let id: String
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

    public var isLoadingHistory = false
    public var historyLoaded = false
    public var error: String?

    public var items: [TranscriptItem] { transcript.items }
    public var isLive: Bool { liveHandle != nil }
    public var isWorking: Bool { liveState == .running || liveState == .starting || liveState == .waiting }
    public var projectName: String { (cwd as NSString).lastPathComponent }

    init(id: String, sessionId: String?, cwd: String, title: String) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
    }

    func loadHistory(_ messages: [JSONValue]) {
        var builder = TranscriptBuilder()
        for m in messages { builder.add(m) }
        // Keep anything that arrived live while history was loading.
        for item in transcript.items { builder.appendExisting(item) }
        transcript = builder
        historyLoaded = true
    }

    func addLocalPrompt(_ text: String) {
        transcript.addLocalUserText(text)
    }

    func addNotice(_ text: String, isError: Bool = false) {
        transcript.addNotice(text, isError: isError)
    }

    /// Apply one live SDK message.
    func apply(_ message: JSONValue) {
        switch message["type"]?.string {
        case "stream_event":
            guard message["parent_tool_use_id"]?.isNull ?? true, let event = message["event"] else { return }
            switch event["type"]?.string {
            case "message_start":
                draftText = ""
                draftThinking = ""
            case "content_block_delta":
                let delta = event["delta"]
                if let t = delta?["text"]?.string { draftText += t }
                if let t = delta?["thinking"]?.string { draftThinking += t }
            default:
                break
            }
        case "assistant":
            draftText = ""
            draftThinking = ""
            transcript.add(message, live: true)
        case "user", "system":
            transcript.add(message, live: true)
        case "result":
            draftText = ""
            draftThinking = ""
            transcript.add(message, live: true)
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
