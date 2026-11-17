import Foundation

/// How much a Mac tool can change, which decides whether it needs your OK.
public enum ToolRisk: String, Sendable, CaseIterable {
    /// Only looks at things. Runs on its own.
    case read
    /// Creates something new or flips a reversible setting. Runs on its own and
    /// shows up as a tool card in the conversation.
    case create
    /// Sends, deletes, moves, quits or runs something. AgentX asks first.
    case ask

    public var label: String {
        switch self {
        case .read: "Runs on its own"
        case .create: "Runs on its own, shown in the chat"
        case .ask: "Asks first"
        }
    }
}

/// One parameter of a Mac tool, described once and turned into a JSON schema for Claude.
public struct ToolParameter: Sendable {
    public enum Kind: Sendable, Equatable {
        case string, integer, number, boolean, stringList
        case choice([String])
    }

    public let name: String
    public let kind: Kind
    public let description: String
    public let required: Bool

    public init(_ name: String, _ kind: Kind, _ description: String, required: Bool = true) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "description": .string(description), "required": .bool(required)]
        switch kind {
        case .string: o["type"] = "string"
        case .integer: o["type"] = "integer"
        case .number: o["type"] = "number"
        case .boolean: o["type"] = "boolean"
        case .stringList: o["type"] = "string[]"
        case .choice(let options):
            o["type"] = "string"
            o["enum"] = .array(options.map(JSONValue.string))
        }
        return .object(o)
    }
}

/// A capability the assistant can use on your Mac. Defined once here, in
/// Swift, next to its implementation; agent-core exposes it to Claude as
/// `mcp__agentx__<name>`.
public struct MacTool: Sendable, Identifiable {
    public let name: String
    public let area: String
    public let summary: String
    public let description: String
    public let risk: ToolRisk
    public let parameters: [ToolParameter]
    /// Its results can contain text other people wrote ("your email"). agent-core
    /// frames them as untrusted data, and reading them marks the conversation
    /// as having seen untrusted content (see SECURITY.md).
    public let untrustedSource: String?
    /// Only for conversations someone is watching (never for scheduled or triggered runs).
    public let attendedOnly: Bool
    let run: @Sendable (ToolArguments) async throws -> String

    public var id: String { name }
    public var qualifiedName: String { "mcp__agentx__\(name)" }

    init(_ name: String, area: String, summary: String, risk: ToolRisk, description: String,
         parameters: [ToolParameter] = [], untrustedSource: String? = nil, attendedOnly: Bool = false,
         run: @escaping @Sendable (ToolArguments) async throws -> String) {
        self.name = name
        self.area = area
        self.summary = summary
        self.risk = risk
        self.description = description
        self.parameters = parameters
        self.untrustedSource = untrustedSource
        self.attendedOnly = attendedOnly
        self.run = run
    }

    var definition: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "description": .string(description), "risk": .string(risk.rawValue),
                                      "parameters": .array(parameters.map(\.json))]
        if let untrustedSource { o["untrusted"] = .string(untrustedSource) }
        if attendedOnly { o["attendedOnly"] = true }
        return .object(o)
    }
}

/// A tool failure Claude should see as a readable message.
public struct ToolError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Typed access to the arguments Claude passed.
public struct ToolArguments: Sendable {
    let values: JSONValue

    func string(_ name: String) throws -> String {
        guard let s = values[name]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            throw ToolError("Missing \"\(name)\".")
        }
        return s
    }

    func optionalString(_ name: String) -> String? {
        guard let s = values[name]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    func int(_ name: String, default value: Int) -> Int { values[name]?.int ?? value }
    func bool(_ name: String, default value: Bool) -> Bool { values[name]?.bool ?? value }
    func stringList(_ name: String) -> [String] { values[name]?.array?.compactMap(\.string) ?? [] }

    /// A file path argument. Credentials, keys and other protected places are refused (PathGuard).
    func path(_ name: String) throws -> URL {
        let raw = (try string(name) as NSString).expandingTildeInPath
        guard raw.hasPrefix("/") else { throw ToolError("\"\(name)\" must be an absolute path or start with ~.") }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        if let reason = PathGuard.reason(for: url) {
            throw ToolError("AgentX blocks access to \(reason) (\(PathGuard.display(url.path))). Don't try another way to reach it.")
        }
        return url
    }

    func date(_ name: String) throws -> Date {
        guard let date = try optionalDate(name) else { throw ToolError("Missing \"\(name)\".") }
        return date
    }

    func optionalDate(_ name: String) throws -> Date? {
        guard let raw = optionalString(name) else { return nil }
        guard let date = ToolDates.parse(raw) else {
            throw ToolError("Couldn't read \"\(raw)\" as a date. Use local time like 2026-11-16T18:00 or 2026-11-16.")
        }
        return date
    }
}

/// Dates in and out of tools: ISO 8601, read as local time unless an offset is given.
enum ToolDates {
    static func parse(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let d = iso.date(from: text) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    static func describe(_ date: Date, allDay: Bool = false) -> String {
        allDay ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
               : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }
}
