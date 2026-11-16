import Foundation

/// One process's resource use, as Activity Monitor would show it.
public struct ProcessUsage: Sendable, Identifiable, Hashable {
    public let pid: Int32
    public let name: String
    /// Percent of one core (can exceed 100 on multi-core work), like Activity Monitor.
    public let cpuPercent: Double
    /// Physical footprint ("Memory" in Activity Monitor).
    public let memoryBytes: UInt64
    public var id: Int32 { pid }
}

/// macOS memory pressure, from kern.memorystatus_vm_pressure_level.
public enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

/// Memory, broken down the way Activity Monitor does it.
public struct MemoryUsage: Sendable, Equatable {
    public var total: UInt64
    /// App memory: anonymous pages apps own (internal minus purgeable).
    public var app: UInt64
    /// Wired memory: locked for the kernel and drivers.
    public var wired: UInt64
    /// Compressed memory.
    public var compressed: UInt64
    /// File-backed and purgeable pages macOS can drop at will.
    public var cached: UInt64
    public var swapUsed: UInt64

    /// "Memory Used" in Activity Monitor.
    public var used: UInt64 { app + wired + compressed }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
    public var free: UInt64 { total > used ? total - used : 0 }
}

public struct DiskUsage: Sendable, Equatable {
    public var total: UInt64
    /// Space available for important files (counts purgeable space as free, like Finder).
    public var available: UInt64
    public var used: UInt64 { total > available ? total - available : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public struct BatteryInfo: Sendable, Equatable {
    /// 0...1
    public var level: Double
    public var isCharging: Bool
    public var onACPower: Bool
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is estimating.
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// Current full-charge capacity relative to design capacity, 0...1.
    public var health: Double?
}

/// Thermal state, mirrored from ProcessInfo so it's Sendable and testable.
public enum ThermalLevel: Int, Sendable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public var label: String {
        switch self {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Throttling"
        }
    }
}

/// Static facts about this Mac.
public struct MachineInfo: Sendable, Equatable {
    public var chip: String
    public var memory: UInt64
    public var cores: Int
    public var osVersion: String

    public static func current() -> MachineInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(
            chip: SystemSampler.sysctlString("machdep.cpu.brand_string") ?? "Mac",
            memory: ProcessInfo.processInfo.physicalMemory,
            cores: ProcessInfo.processInfo.activeProcessorCount,
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        )
    }
}

/// Everything the System section shows, at one moment.
public struct SystemSnapshot: Sendable, Equatable, Identifiable {
    public var date: Date
    /// Whole-machine CPU use, 0...1.
    public var cpu: Double
    public var cpuPerCore: [Double]
    public var loadAverage: [Double]
    public var memory: MemoryUsage
    public var memoryPressure: MemoryPressure
    public var disk: DiskUsage
    public var battery: BatteryInfo?
    /// Bytes per second across physical interfaces.
    public var networkIn: Double
    public var networkOut: Double
    /// Top processes by CPU and by memory (your own processes; macOS hides others' usage).
    public var processes: [ProcessUsage]
    public var thermal: ThermalLevel
    public var uptime: TimeInterval

    public var id: Date { date }

    public func topProcesses(byMemory: Bool, limit: Int = 10) -> [ProcessUsage] {
        let sorted = byMemory
            ? processes.sorted { $0.memoryBytes > $1.memoryBytes }
            : processes.sorted { ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes) }
        return Array(sorted.prefix(limit))
    }

    /// Plain-text summary for Claude ("why is my Mac slow?").
    public func report(machine: MachineInfo) -> String {
        var lines: [String] = []
        lines.append("Mac: \(machine.chip), \(Format.bytes(machine.memory)) RAM, \(machine.cores) cores, \(machine.osVersion), up \(Format.duration(uptime))")
        lines.append("CPU: \(Format.percent(cpu)) overall; load average \(loadAverage.map { String(format: "%.2f", $0) }.joined(separator: ", ")); thermal state \(thermal.label.lowercased())")
        lines.append("Memory: \(Format.bytes(memory.used)) used of \(Format.bytes(memory.total)) (app \(Format.bytes(memory.app)), wired \(Format.bytes(memory.wired)), compressed \(Format.bytes(memory.compressed))); swap \(Format.bytes(memory.swapUsed)); pressure \(memoryPressure.label.lowercased())")
        lines.append("Disk: \(Format.bytes(disk.available)) free of \(Format.bytes(disk.total))")
        if let b = battery {
            var text = "Battery: \(Format.percent(b.level)), \(b.isCharging ? "charging" : b.onACPower ? "on power, not charging" : "on battery")"
            if let m = b.minutesRemaining { text += ", \(Format.duration(TimeInterval(m * 60))) \(b.isCharging ? "to full" : "remaining")" }
            if let c = b.cycleCount { text += ", \(c) cycles" }
            if let h = b.health { text += ", health \(Format.percent(h))" }
            lines.append(text)
        }
        lines.append("Network: down \(Format.rate(networkIn)), up \(Format.rate(networkOut))")
        lines.append("Top processes by CPU: " + topProcesses(byMemory: false, limit: 8)
            .map { "\($0.name) (pid \($0.pid)) \(String(format: "%.0f", $0.cpuPercent))% CPU, \(Format.bytes($0.memoryBytes))" }
            .joined(separator: "; "))
        lines.append("Top processes by memory: " + topProcesses(byMemory: true, limit: 8)
            .map { "\($0.name) (pid \($0.pid)) \(Format.bytes($0.memoryBytes))" }
            .joined(separator: "; "))
        return lines.joined(separator: "\n")
    }
}

/// Number formatting shared by the System views and the report.
public enum Format {
    public static func bytes(_ value: UInt64) -> String {
        formatter(.memory).string(fromByteCount: Int64(clamping: value))
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        formatter(.file).string(fromByteCount: Int64(max(0, bytesPerSecond))) + "/s"
    }

    private static func formatter(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false   // "0 KB", not "Zero KB"
        return f
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: max(0, seconds)) ?? "—"
    }
}
