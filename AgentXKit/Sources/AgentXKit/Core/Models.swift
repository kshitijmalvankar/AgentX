import Foundation

/// Who is signed in to Claude Code on this Mac (from the SDK's `accountInfo`).
public struct AccountInfo: Codable, Sendable, Equatable {
    public var email: String?
    public var organization: String?
    public var subscriptionType: String?
    public var tokenSource: String?
    public var apiKeySource: String?
    public var apiProvider: String?

    /// True when Claude Code has a usable login (subscription or API key).
    public var isSignedIn: Bool {
        if let s = subscriptionType, !s.isEmpty { return true }
        if let k = apiKeySource, k != "none" { return true }
        if let t = tokenSource, t != "none" { return true }
        return apiProvider != nil && apiProvider != "firstParty"
    }

    public var planLabel: String {
        if let s = subscriptionType, !s.isEmpty {
            // Claude Code reports e.g. "Claude Pro"; older versions said just "pro".
            return s.lowercased().hasPrefix("claude") ? s : "Claude \(s.capitalized)"
        }
        if let k = apiKeySource, k != "none" { return "API key" }
        if let p = apiProvider, p != "firstParty" { return p.capitalized }
        return "Not signed in"
    }
}

public struct ModelInfo: Codable, Sendable, Identifiable, Hashable {
    public var value: String
    public var displayName: String
    public var description: String?
    /// The effort levels the model takes ("low" … "max"), when the SDK says.
    public var supportedEffortLevels: [String]?
    public var id: String { value }
}

/// Reasoning effort: how hard Claude thinks before answering (and how much plan it uses).
public enum EffortOption: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high, xhigh, max

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }

    /// The levels `model` takes; all of them when it doesn't say.
    public static func levels(for model: ModelInfo?) -> [EffortOption] {
        guard let listed = model?.supportedEffortLevels, !listed.isEmpty else { return allCases }
        return allCases.filter { listed.contains($0.rawValue) }
    }
}

public struct AccountSnapshot: Codable, Sendable, Equatable {
    public var account: AccountInfo
    public var models: [ModelInfo]
}

/// One Claude Code session on disk (from the SDK's `listSessions`).
public struct SessionSummary: Codable, Sendable, Identifiable, Hashable {
    public var sessionId: String
    public var summary: String
    public var lastModified: Double
    public var fileSize: Double?
    public var customTitle: String?
    public var firstPrompt: String?
    public var gitBranch: String?
    public var cwd: String?
    public var tag: String?
    public var createdAt: Double?
    public var archived: Bool?
    /// Set when AgentX is currently running this session.
    public var liveHandle: String?
    public var liveState: String?

    public var id: String { sessionId }
    public var title: String { customTitle ?? summary }
    public var modifiedDate: Date { Date(timeIntervalSince1970: lastModified / 1000) }
    public var projectName: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "Unknown project" }
}

/// Live state of a session AgentX is driving.
public enum LiveState: String, Sendable {
    case starting, running, waiting, idle, ended

    public var label: String {
        switch self {
        case .starting: "Starting"
        case .running: "Working"
        case .waiting: "Needs approval"
        case .idle: "Ready"
        case .ended: "Stopped"
        }
    }

    public var symbol: String {
        switch self {
        case .starting: "hourglass"
        case .running: "bolt.fill"
        case .waiting: "hand.raised.fill"
        case .idle: "checkmark.circle"
        case .ended: "stop.circle"
        }
    }
}

/// Claude Code's permission modes for coding sessions. "Bypass permissions"
/// (skip every check) and "don't ask" are left out on purpose.
public enum PermissionModeOption: String, CaseIterable, Identifiable, Sendable {
    case `default`, acceptEdits, plan, auto

    public var id: String { rawValue }
    public var shortLabel: String {
        switch self {
        case .default: "Ask"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan"
        case .auto: "Auto"
        }
    }
    public var label: String {
        switch self {
        case .default: "Ask before edits and commands"
        case .acceptEdits: "Accept file edits, ask for commands"
        case .plan: "Plan only (no changes)"
        case .auto: "Auto (Claude approves safe steps, asks about the rest)"
        }
    }
    public var symbol: String {
        switch self {
        case .default: "hand.raised"
        case .acceptEdits: "pencil.line"
        case .plan: "list.bullet.clipboard"
        case .auto: "wand.and.sparkles"
        }
    }
}

/// Plan usage reported by Claude Code (subscription users).
public struct RateLimitInfo: Sendable, Equatable {
    public var status: String
    public var limitType: String?
    public var utilization: Double?
    public var resetsAt: Date?

    init?(_ json: JSONValue) {
        guard let status = json["status"]?.string else { return nil }
        self.status = status
        self.limitType = json["rateLimitType"]?.string
        self.utilization = json["utilization"]?.number
        self.resetsAt = json["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
    }
}
