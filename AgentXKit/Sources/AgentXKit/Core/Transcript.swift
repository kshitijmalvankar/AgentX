import Foundation

/// One tool call Claude made, plus its result once it arrives.
public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var result: String?
    public var isError = false

    public var isFinished: Bool { result != nil }
}

public struct RunSummary: Sendable, Equatable {
    public var isError: Bool
    public var subtype: String
    public var durationMs: Double?
    public var costUSD: Double?
    public var turns: Int?
}

/// Something to show in a conversation.
public enum TranscriptKind: Sendable, Equatable {
    case user(String)
    case assistant(String)
    case thinking(String)
    case tool(ToolCall)
    case notice(String, isError: Bool)
    case result(RunSummary)
}

public struct TranscriptItem: Identifiable, Sendable, Equatable {
    public let id: String
    public var kind: TranscriptKind
}

/// Builds a flat list of transcript items from Claude Code messages.
///
/// The same Anthropic message format shows up in two places:
/// - history (`getSessionMessages`): `{type, uuid, message: {role, content}}`
/// - live SDK events: `{type: "assistant" | "user" | "result" | ..., message: {...}}`
public struct TranscriptBuilder: Sendable {
    public private(set) var items: [TranscriptItem] = []
    private var toolIndex: [String: Int] = [:]

    public init() {}

    /// Add one message. Subagent messages (parent_tool_use_id set) are skipped:
    /// their work shows up as the parent Agent tool card.
    /// `live` messages come from a running session: user text there is an echo
    /// of a prompt we already showed, so only tool results are taken from it.
    public mutating func add(_ message: JSONValue, live: Bool = false) {
        if let parent = message["parent_tool_use_id"], !parent.isNull { return }
        let uuid = message["uuid"]?.string ?? UUID().uuidString

        switch message["type"]?.string {
        case "assistant":
            addBlocks(message["message"]?["content"], role: "assistant", uuid: uuid)
        case "user":
            addBlocks(message["message"]?["content"], role: live ? "user-live" : "user", uuid: uuid)
        case "result":
            items.append(TranscriptItem(id: uuid, kind: .result(RunSummary(
                isError: message["is_error"]?.bool ?? false,
                subtype: message["subtype"]?.string ?? "success",
                durationMs: message["duration_ms"]?.number,
                costUSD: message["total_cost_usd"]?.number,
                turns: message["num_turns"]?.int
            ))))
            if message["is_error"]?.bool == true, let errors = message["errors"]?.array {
                let text = errors.compactMap(\.string).joined(separator: "\n")
                if !text.isEmpty { items.append(TranscriptItem(id: uuid + "-err", kind: .notice(text, isError: true))) }
            }
        case "system":
            if message["subtype"]?.string == "compact_boundary" {
                items.append(TranscriptItem(id: uuid, kind: .notice("Conversation compacted", isError: false)))
            }
        default:
            break
        }
    }

    /// Add text the user just typed (shown immediately, before Claude echoes anything).
    public mutating func addLocalUserText(_ text: String) {
        items.append(TranscriptItem(id: UUID().uuidString, kind: .user(ScreenContext.displayText(text))))
    }

    public mutating func addNotice(_ text: String, isError: Bool) {
        items.append(TranscriptItem(id: UUID().uuidString, kind: .notice(text, isError: isError)))
    }

    private mutating func addBlocks(_ content: JSONValue?, role: String, uuid: String) {
        guard let content else { return }

        if let text = content.string {
            switch role {
            case "user": addUserText(text, id: uuid)
            case "user-live": break  // echo of a prompt we already showed
            default: append(.assistant(text), id: uuid)
            }
            return
        }

        for (i, block) in (content.array ?? []).enumerated() {
            let id = "\(uuid)-\(i)"
            switch block["type"]?.string {
            case "text":
                let text = block["text"]?.string ?? ""
                switch role {
                case "user": addUserText(text, id: id)
                case "user-live": break
                default: if !text.isEmpty { append(.assistant(text), id: id) }
                }
            case "thinking":
                if let t = block["thinking"]?.string, !t.isEmpty { append(.thinking(t), id: id) }
            case "tool_use":
                let call = ToolCall(id: block["id"]?.string ?? id, name: block["name"]?.string ?? "Tool", input: block["input"] ?? [:])
                toolIndex[call.id] = items.count
                append(.tool(call), id: id)
            case "tool_result":
                attachResult(block)
            case "image":
                append(role == "assistant" ? .assistant("[image]") : .user("[image]"), id: id)
            default:
                break
            }
        }
    }

    private mutating func addUserText(_ text: String, id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Claude Code stores some bookkeeping as user text; hide or condense it.
        if trimmed.hasPrefix("<system-reminder>") || trimmed.hasPrefix("<local-command-caveat>") { return }
        if trimmed.hasPrefix("[Request interrupted") { append(.notice("Interrupted", isError: false), id: id); return }
        if let command = Self.tag("command-name", in: trimmed) {
            let args = Self.tag("command-args", in: trimmed) ?? ""
            append(.notice("Ran \(command) \(args)".trimmingCharacters(in: .whitespaces), isError: false), id: id)
            return
        }
        if trimmed.hasPrefix("<local-command-stdout>") {
            let out = Self.tag("local-command-stdout", in: trimmed) ?? ""
            if !out.isEmpty { append(.notice(out, isError: false), id: id) }
            return
        }
        // Screen context sent with a message shows as a short note, not the whole block.
        append(.user(ScreenContext.displayText(trimmed)), id: id)
    }

    private mutating func attachResult(_ block: JSONValue) {
        guard let toolID = block["tool_use_id"]?.string, let index = toolIndex[toolID],
              case .tool(var call) = items[index].kind else { return }
        call.result = Self.capped((block["content"] ?? .null).flattenedText)
        call.isError = block["is_error"]?.bool ?? false
        items[index].kind = .tool(call)
    }

    private mutating func append(_ kind: TranscriptKind, id: String) {
        // History can repeat a uuid across content splits; keep ids unique.
        let uniqueID = items.contains(where: { $0.id == id }) ? id + "-" + UUID().uuidString.prefix(6) : id
        items.append(TranscriptItem(id: uniqueID, kind: kind))
    }

    /// Tool results can be huge (a whole file, a long log). Keep the start in
    /// memory; the full text stays in the session file on disk.
    static let resultLimit = 20_000

    static func capped(_ text: String) -> String {
        guard text.utf8.count > resultLimit * 2 else { return text }
        let kept = text.prefix(resultLimit)
        return kept + "\n… (output shortened in AgentX; \(text.count - kept.count) more characters are in the session file)"
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
