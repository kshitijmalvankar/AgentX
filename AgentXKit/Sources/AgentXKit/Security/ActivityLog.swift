import Foundation
import Observation

/// One thing AgentX or Claude did that's worth a record: a tool that changed
/// something, an approval, a policy decision, a stopped run.
public struct ActivityEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Claude ran a tool that changes something or reaches the network.
        case tool
        /// The security policy blocked, asked about, or flagged something.
        case policy
        /// You (or a timeout) answered an approval.
        case approval
        /// An automation started or finished.
        case automation
        /// Stop everything was used.
        case killSwitch
        /// A link (agentx://…) was opened or refused.
        case link
    }

    public var id = UUID()
    public var date = Date()
    public var kind: Kind
    /// "ran", "blocked", "asked", "tainted", "allowed", "denied", "refused", …
    public var action: String
    public var tool: String?
    public var detail: String
    /// The conversation or automation it came from.
    public var origin: String?
    public var sessionId: String?

    public var toolLabel: String? {
        tool.map { $0.hasPrefix("mcp__agentx__") ? String($0.dropFirst("mcp__agentx__".count)) : $0 }
    }
}

/// Append-only record of what happened, in `activity.jsonl` (readable only
/// by you). Entries older than 30 days are dropped when AgentX starts.
@MainActor
@Observable
public final class ActivityLog {
    public static let retention: TimeInterval = 30 * 86_400
    static let recentLimit = 500

    /// Newest first.
    public private(set) var recent: [ActivityEntry] = []
    public let fileURL: URL

    @ObservationIgnored private let queue = DispatchQueue(label: "agentx.activity-log")

    public init(fileURL: URL = AppChannel.current.dataFile("activity.jsonl")) {
        self.fileURL = fileURL
        load()
    }

    public func record(_ entry: ActivityEntry) {
        recent.insert(entry, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        guard var encoded = try? Self.encoder.encode(entry) else { return }
        encoded.append(0x0A)
        let line = encoded
        let url = fileURL
        queue.async { try? SecureFile.append(line, to: url) }
    }

    public func record(_ kind: ActivityEntry.Kind, _ action: String, tool: String? = nil, detail: String,
                       origin: String? = nil, sessionId: String? = nil) {
        record(ActivityEntry(kind: kind, action: action, tool: tool, detail: detail, origin: origin, sessionId: sessionId))
    }

    /// Read the log, dropping entries past the retention window.
    func load(now: Date = Date()) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let cutoff = now.addingTimeInterval(-Self.retention)
        var kept: [ActivityEntry] = []
        var dropped = false
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let entry = try? Self.decoder.decode(ActivityEntry.self, from: Data(line)) else { dropped = true; continue }
            if entry.date < cutoff { dropped = true } else { kept.append(entry) }
        }
        recent = Array(kept.reversed().prefix(Self.recentLimit))
        if dropped {
            let body = kept.compactMap { try? Self.encoder.encode($0) }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
            try? SecureFile.write(body, to: fileURL)
        }
    }

    public func clear() {
        recent = []
        let url = fileURL
        queue.async { try? SecureFile.write(Data(), to: url) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
