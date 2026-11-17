import Foundation

/// What the phone asks the Mac. Every request carries an id; the Mac answers
/// with `ServerEvent.result` for that id.
public enum ClientRequest: Codable, Sendable, Equatable {
    /// First message after the handshake.
    case hello(deviceName: String, appVersion: String)
    /// Send a fresh snapshot now.
    case refresh
    /// Allow or deny a waiting approval (the phone already checked Face ID).
    case answer(approvalID: String, allow: Bool)
    /// The kill switch (the phone already checked Face ID).
    case stopEverything
    /// The messages of a conversation on the Mac.
    case transcript(conversationID: String)
    /// Send a message to a conversation on the Mac (nil: start a new one).
    case send(conversationID: String?, text: String)
    /// Tick a reminder off (or back on) from the Today list.
    case setReminder(id: String, completed: Bool)
}

public struct ClientEnvelope: Codable, Sendable, Equatable {
    public var id: Int
    public var request: ClientRequest
    public init(id: Int, request: ClientRequest) { self.id = id; self.request = request }
}

/// What the Mac sends the phone.
public enum ServerEvent: Codable, Sendable, Equatable {
    /// This phone is new: the Mac is asking you to confirm it.
    case awaitingConfirmation
    /// You declined the phone on the Mac (or revoked it).
    case refused
    /// The current state of things (sent on connect and whenever it changes).
    case snapshot(RemoteSnapshot)
    /// A conversation's messages (after `transcript`, and again as it changes).
    case transcript(RemoteTranscript)
    /// The answer to a request.
    case result(id: Int, error: String?, conversationID: String?)
}

/// Everything the phone shows, in one value. Small enough to send whole.
public struct RemoteSnapshot: Codable, Sendable, Equatable {
    public struct Vitals: Codable, Sendable, Equatable {
        public var cpu: Double
        public var memoryUsed: UInt64
        public var memoryTotal: UInt64
        public var memoryPressure: String
        public var diskFree: UInt64
        public var diskTotal: UInt64
        public var batteryLevel: Double?
        public var charging: Bool?
        public var thermal: String
        public init(cpu: Double, memoryUsed: UInt64, memoryTotal: UInt64, memoryPressure: String, diskFree: UInt64,
                    diskTotal: UInt64, batteryLevel: Double?, charging: Bool?, thermal: String) {
            self.cpu = cpu; self.memoryUsed = memoryUsed; self.memoryTotal = memoryTotal; self.memoryPressure = memoryPressure
            self.diskFree = diskFree; self.diskTotal = diskTotal; self.batteryLevel = batteryLevel; self.charging = charging
            self.thermal = thermal
        }
    }

    public struct UsageLimit: Codable, Sendable, Equatable {
        public var label: String
        public var fraction: Double
        public var resetsAt: Date?
        public init(label: String, fraction: Double, resetsAt: Date?) { self.label = label; self.fraction = fraction; self.resetsAt = resetsAt }
    }

    public struct Approval: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var headline: String
        public var tool: String
        /// One line ("Send an email to …").
        public var summary: String
        /// The full input, pretty-printed, so you see exactly what you approve.
        public var detail: String
        /// Why the security policy asked, if it did.
        public var policyReason: String?
        /// The conversation or automation it came from.
        public var origin: String?
        public var receivedAt: Date
        public var unattended: Bool
        public init(id: String, headline: String, tool: String, summary: String, detail: String, policyReason: String?,
                    origin: String?, receivedAt: Date, unattended: Bool) {
            self.id = id; self.headline = headline; self.tool = tool; self.summary = summary; self.detail = detail
            self.policyReason = policyReason; self.origin = origin; self.receivedAt = receivedAt; self.unattended = unattended
        }
    }

    public struct Conversation: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var updated: Date?
        /// "Working", "Needs approval", "Ready", or nil when not running.
        public var state: String?
        /// A Mac conversation (with Mac tools) or a coding session.
        public var isMac: Bool
        public var project: String?
        public init(id: String, title: String, updated: Date?, state: String?, isMac: Bool, project: String?) {
            self.id = id; self.title = title; self.updated = updated; self.state = state; self.isMac = isMac; self.project = project
        }
    }

    public struct AgendaItem: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// "09:30", "All day", "Today", "Overdue · 15 Nov"
        public var when: String
        public var isReminder: Bool
        public var isOverdue: Bool
        /// A reminder ticked off today (shown done, can be undone). Optional so older Macs still decode.
        public var done: Bool?
        /// The calendar or Reminders list.
        public var source: String?
        /// Location (events).
        public var location: String?
        public var notes: String?
        public init(id: String, title: String, when: String, isReminder: Bool, isOverdue: Bool,
                    done: Bool? = nil, source: String? = nil, location: String? = nil, notes: String? = nil) {
            self.id = id; self.title = title; self.when = when; self.isReminder = isReminder; self.isOverdue = isOverdue
            self.done = done; self.source = source; self.location = location; self.notes = notes
        }
        public var isDone: Bool { done ?? false }
    }

    public struct Automation: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var next: Date?
        /// "succeeded", "failed", "skipped", "running", or nil (never ran).
        public var lastStatus: String?
        public var lastSummary: String?
        public var lastRun: Date?
        public init(id: String, name: String, next: Date?, lastStatus: String?, lastSummary: String?, lastRun: Date?) {
            self.id = id; self.name = name; self.next = next; self.lastStatus = lastStatus; self.lastSummary = lastSummary; self.lastRun = lastRun
        }
    }

    public struct Activity: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var date: Date
        public var kind: String
        public var action: String
        public var tool: String?
        public var detail: String
        public var origin: String?
        public init(id: String, date: Date, kind: String, action: String, tool: String?, detail: String, origin: String?) {
            self.id = id; self.date = date; self.kind = kind; self.action = action; self.tool = tool; self.detail = detail; self.origin = origin
        }
    }

    public var macName: String
    public var appName: String
    public var date: Date
    public var planLabel: String?
    public var vitals: Vitals?
    public var usage: [UsageLimit]
    public var approvals: [Approval]
    /// Mac conversations (newest first) followed by coding sessions that are running.
    public var conversations: [Conversation]
    public var today: [AgendaItem]
    public var automations: [Automation]
    public var automationsPaused: Bool
    public var activity: [Activity]
    /// What this phone may do (set on the Mac in Settings → iPhone).
    public var canApprove: Bool
    public var canMessage: Bool
    /// Optional so a snapshot from an older Mac still decodes (nil: no).
    public var canEditReminders: Bool?

    public init(macName: String, appName: String, date: Date = Date(), planLabel: String? = nil, vitals: Vitals? = nil,
                usage: [UsageLimit] = [], approvals: [Approval] = [], conversations: [Conversation] = [],
                today: [AgendaItem] = [], automations: [Automation] = [], automationsPaused: Bool = false,
                activity: [Activity] = [], canApprove: Bool = true, canMessage: Bool = true, canEditReminders: Bool = false) {
        self.macName = macName; self.appName = appName; self.date = date; self.planLabel = planLabel; self.vitals = vitals
        self.usage = usage; self.approvals = approvals; self.conversations = conversations; self.today = today
        self.automations = automations; self.automationsPaused = automationsPaused; self.activity = activity
        self.canApprove = canApprove; self.canMessage = canMessage; self.canEditReminders = canEditReminders
    }
}

/// A conversation's messages, simplified for the phone.
public struct RemoteTranscript: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public enum Role: String, Codable, Sendable { case user, assistant, tool, notice }
        public var id: String
        public var role: Role
        public var text: String
        public init(id: String, role: Role, text: String) { self.id = id; self.role = role; self.text = text }
    }

    public var conversationID: String
    public var title: String
    public var items: [Item]
    /// Claude is still working (more is coming).
    public var isWorking: Bool
    /// Text streaming in right now.
    public var draft: String?

    public init(conversationID: String, title: String, items: [Item], isWorking: Bool, draft: String?) {
        self.conversationID = conversationID; self.title = title; self.items = items; self.isWorking = isWorking; self.draft = draft
    }
}

/// JSON coders both sides use.
public enum RemoteCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Just the id of a request, for answering one this side can't decode.
public struct RequestID: Codable, Sendable {
    public var id: Int
}
