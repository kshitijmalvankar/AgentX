import Foundation

/// What the desktop widgets show. AgentX writes it; the widget extension
/// (which is sandboxed) reads it. Kept tiny and dependency-free.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct UsageWindow: Codable, Sendable, Equatable {
        public var label: String
        /// 0…1
        public var fraction: Double
        public var resetsAt: Date?
        public init(label: String, fraction: Double, resetsAt: Date?) {
            self.label = label; self.fraction = fraction; self.resetsAt = resetsAt
        }
    }

    public struct Activity: Codable, Sendable, Equatable {
        public var title: String
        /// "Working", "Needs approval", "Ready"
        public var state: String
        public init(title: String, state: String) { self.title = title; self.state = state }
    }

    public struct Vitals: Codable, Sendable, Equatable {
        public var cpu: Double
        public var memoryUsed: UInt64
        public var memoryTotal: UInt64
        /// "Normal", "Elevated", "Critical"
        public var memoryPressure: String
        public var diskFree: UInt64
        public var diskTotal: UInt64
        public var batteryLevel: Double?
        public var charging: Bool?
        public init(cpu: Double, memoryUsed: UInt64, memoryTotal: UInt64, memoryPressure: String,
                    diskFree: UInt64, diskTotal: UInt64, batteryLevel: Double?, charging: Bool?) {
            self.cpu = cpu; self.memoryUsed = memoryUsed; self.memoryTotal = memoryTotal; self.memoryPressure = memoryPressure
            self.diskFree = diskFree; self.diskTotal = diskTotal; self.batteryLevel = batteryLevel; self.charging = charging
        }
    }

    public struct GitHub: Codable, Sendable, Equatable {
        public var login: String
        public var totalContributions: Int
        public var currentStreak: Int
        /// Recent weeks, oldest first; each week Sunday→Saturday as levels 0…4 (a partial first week is padded with -1).
        public var weeks: [[Int]]
        public init(login: String, totalContributions: Int, currentStreak: Int, weeks: [[Int]]) {
            self.login = login; self.totalContributions = totalContributions; self.currentStreak = currentStreak; self.weeks = weeks
        }
    }

    public struct NextAutomation: Codable, Sendable, Equatable {
        public var name: String
        public var date: Date
        public init(name: String, date: Date) { self.name = name; self.date = date }
    }

    /// An automation, for the Run Automation control.
    public struct AutomationRef: Codable, Sendable, Equatable, Hashable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public var updatedAt: Date
    public var planLabel: String?
    public var usage: [UsageWindow]
    public var runningSessions: Int
    public var waitingApprovals: Int
    public var activity: [Activity]
    public var vitals: Vitals?
    public var github: GitHub?
    public var nextAutomation: NextAutomation?
    /// All your automations (nil in snapshots written before controls existed).
    public var automations: [AutomationRef]?

    public init(updatedAt: Date = Date(), planLabel: String? = nil, usage: [UsageWindow] = [], runningSessions: Int = 0,
                waitingApprovals: Int = 0, activity: [Activity] = [], vitals: Vitals? = nil, github: GitHub? = nil,
                nextAutomation: NextAutomation? = nil, automations: [AutomationRef]? = nil) {
        self.updatedAt = updatedAt; self.planLabel = planLabel; self.usage = usage; self.runningSessions = runningSessions
        self.waitingApprovals = waitingApprovals; self.activity = activity; self.vitals = vitals; self.github = github
        self.nextAutomation = nextAutomation; self.automations = automations
    }

    // MARK: File

    /// The real home folder, even inside the widget's sandbox (where
    /// NSHomeDirectory() points at the container instead).
    public static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    public static var fileURL: URL {
        SharedChannel.dataDirectory.appendingPathComponent("widget-snapshot.json")
    }

    public static func load(from url: URL = fileURL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func save(to url: URL = fileURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Shown in the widget gallery and while there's no data yet.
    public static let preview = WidgetSnapshot(
        planLabel: "Claude Pro",
        usage: [.init(label: "Current session", fraction: 0.42, resetsAt: Date().addingTimeInterval(7200)),
                .init(label: "This week", fraction: 0.18, resetsAt: Date().addingTimeInterval(3 * 86_400))],
        runningSessions: 1, waitingApprovals: 1,
        activity: [.init(title: "Fix the login bug", state: "Needs approval")],
        vitals: .init(cpu: 0.23, memoryUsed: 11 << 30, memoryTotal: 16 << 30, memoryPressure: "Normal",
                      diskFree: 80 << 30, diskTotal: 250 << 30, batteryLevel: 0.8, charging: false),
        github: .init(login: "you", totalContributions: 321, currentStreak: 4,
                      weeks: (0..<20).map { w in (0..<7).map { d in (w * 7 + d) % 5 } }),
        nextAutomation: .init(name: "Morning brief", date: Date().addingTimeInterval(3600)),
        automations: [.init(id: UUID().uuidString, name: "Morning brief")])
}
