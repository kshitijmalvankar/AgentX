import AppKit
import SwiftUI

/// System section: the Mac's vitals, live, with an "Ask Claude" button.
struct SystemView: View {
    @Environment(AppModel.self) private var model
    private var monitor: SystemMonitor { model.system }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let s = monitor.latest {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], alignment: .leading, spacing: 16) {
                        CPUCard(snapshot: s, history: monitor.history, cores: monitor.machine.cores)
                        MemoryCard(snapshot: s)
                        NetworkCard(snapshot: s, history: monitor.history)
                        DiskCard(disk: s.disk)
                        if let battery = s.battery { BatteryCard(battery: battery) }
                    }
                    ProcessesCard(snapshot: s)
                } else {
                    ProgressView("Reading your Mac's vitals…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(24)
        }
        .navigationTitle("System")
        .onAppear { monitor.beginWatching() }
        .onDisappear { monitor.endWatching() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.machine.chip).font(.largeTitle.bold())
                Text("\(Format.bytes(monitor.machine.memory)) memory · \(monitor.machine.cores) cores · \(monitor.machine.osVersion)\(monitor.latest.map { " · up \(Format.duration($0.uptime))" } ?? "")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let thermal = monitor.latest?.thermal {
                StatusLabel(level: thermal.statusLevel, text: thermal.label)
                    .help("Thermal state reported by macOS")
            }
            Button("Ask Claude", systemImage: "sparkles") { model.askClaudeAboutSystem() }
                .primaryButton()
                .controlSize(.large)
                .disabled(monitor.latest == nil)
                .help("Starts a Claude Code session with this snapshot to explain what's using your Mac. It asks before running commands, and uses your plan.")
        }
    }
}

extension ThermalLevel {
    var statusLevel: StatusLabel.Level {
        switch self {
        case .nominal: .good
        case .fair: .warning
        case .serious: .serious
        case .critical: .critical
        }
    }
}

extension MemoryPressure {
    var statusLevel: StatusLabel.Level {
        switch self {
        case .normal: .good
        case .warning: .warning
        case .critical: .critical
        }
    }
}

/// Big number + caption, the way each card leads.
private struct Hero: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Colored swatch + name + value: the legend doubles as the direct label.
private struct LegendRow: View {
    let color: Color
    let name: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

private struct CPUCard: View {
    let snapshot: SystemSnapshot
    let history: [SystemSnapshot]
    let cores: Int

    var body: some View {
        GlassCard("CPU", symbol: "cpu") {
            Text("load \(String(format: "%.2f", snapshot.loadAverage.first ?? 0))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Load average over the last 1, 5 and 15 minutes: " + snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        } content: {
            Hero(value: Format.percent(snapshot.cpu), caption: "in use across \(cores) cores")
            Sparkline(points: history.map { SparkPoint(date: $0.date, series: "CPU", value: $0.cpu) },
                      series: [("CPU", Viz.series1)], yDomain: 0...1, format: Format.percent)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(snapshot.cpuPerCore.enumerated()), id: \.offset) { index, value in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Viz.track)
                        RoundedRectangle(cornerRadius: 2).fill(Viz.sequential)
                            .frame(height: max(2, 28 * value))
                    }
                    .frame(height: 28)
                    .help("Core \(index + 1): \(Format.percent(value))")
                }
            }
            Text("Per core").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MemoryCard: View {
    let snapshot: SystemSnapshot

    var body: some View {
        let m = snapshot.memory
        GlassCard("Memory", symbol: "memorychip") {
            StatusLabel(level: snapshot.memoryPressure.statusLevel, text: "\(snapshot.memoryPressure.label) pressure")
                .help("Memory pressure: how hard macOS is working to free memory. Elevated means it's compressing and swapping more.")
        } content: {
            Hero(value: Format.bytes(m.used), caption: "used of \(Format.bytes(m.total))")
            SegmentedBar(segments: [
                .init(name: "App", value: Double(m.app), color: Viz.series1),
                .init(name: "Wired", value: Double(m.wired), color: Viz.series2),
                .init(name: "Compressed", value: Double(m.compressed), color: Viz.series3),
            ], total: Double(m.total))
            VStack(spacing: 4) {
                LegendRow(color: Viz.series1, name: "App", value: Format.bytes(m.app))
                LegendRow(color: Viz.series2, name: "Wired", value: Format.bytes(m.wired))
                LegendRow(color: Viz.series3, name: "Compressed", value: Format.bytes(m.compressed))
                LegendRow(color: Viz.track, name: "Free", value: Format.bytes(m.free))
            }
            Text("Swap used: \(Format.bytes(m.swapUsed))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NetworkCard: View {
    let snapshot: SystemSnapshot
    let history: [SystemSnapshot]

    var body: some View {
        GlassCard("Network", symbol: "network") {
            EmptyView()
        } content: {
            HStack(spacing: 20) {
                Hero(value: Format.rate(snapshot.networkIn), caption: "Download")
                Hero(value: Format.rate(snapshot.networkOut), caption: "Upload")
            }
            Sparkline(points: history.flatMap { [SparkPoint(date: $0.date, series: "Down", value: $0.networkIn),
                                                 SparkPoint(date: $0.date, series: "Up", value: $0.networkOut)] },
                      series: [("Down", Viz.series1), ("Up", Viz.series2)], format: Format.rate)
            HStack(spacing: 16) {
                LegendRow(color: Viz.series1, name: "Down", value: Format.rate(snapshot.networkIn))
                LegendRow(color: Viz.series2, name: "Up", value: Format.rate(snapshot.networkOut))
            }
            Text("Wi-Fi, Ethernet and cellular; VPN traffic is counted once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DiskCard: View {
    let disk: DiskUsage

    var body: some View {
        GlassCard("Disk", symbol: "internaldrive") {
            if disk.total > 0, Double(disk.available) / Double(disk.total) < 0.1 {
                StatusLabel(level: .warning, text: "Low space")
            }
        } content: {
            Hero(value: Format.bytes(disk.available), caption: "free of \(Format.bytes(disk.total))")
            CapacityBar(fraction: disk.usedFraction)
            LegendRow(color: Viz.sequential, name: "Used", value: Format.bytes(disk.used))
            Text("Free space includes purgeable files macOS can clear, like Finder shows.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BatteryCard: View {
    let battery: BatteryInfo

    var body: some View {
        GlassCard("Battery", symbol: symbol) {
            if battery.level < 0.2 && !battery.onACPower {
                StatusLabel(level: .critical, text: "Low battery")
            }
        } content: {
            Hero(value: Format.percent(battery.level), caption: stateText)
            CapacityBar(fraction: battery.level)
            HStack(spacing: 16) {
                if let cycles = battery.cycleCount { LegendRow(color: .clear, name: "Cycles", value: "\(cycles)") }
                if let health = battery.health { LegendRow(color: .clear, name: "Health", value: Format.percent(health)) }
            }
        }
    }

    private var stateText: String {
        let time = battery.minutesRemaining.map { Format.duration(TimeInterval($0 * 60)) }
        if battery.isCharging { return "Charging" + (time.map { " · \($0) to full" } ?? "") }
        if battery.onACPower { return "On power, not charging" }
        return "On battery" + (time.map { " · \($0) left" } ?? "")
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct ProcessesCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: SystemSnapshot
    @State private var byMemory = false

    var body: some View {
        GlassCard("Top processes", symbol: "list.bullet.rectangle") {
            HStack {
                Picker("Sort by", selection: $byMemory) {
                    Text("CPU").tag(false)
                    Text("Memory").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                .secondaryButton()
            }
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Process")
                    Text("CPU").gridColumnAlignment(.trailing)
                    Text("Memory").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                ForEach(snapshot.topProcesses(byMemory: byMemory, limit: 10)) { process in
                    let shown = model.system.display(process)
                    GridRow {
                        HStack(spacing: 8) {
                            if let icon = shown.icon {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "gearshape").frame(width: 18, height: 18).foregroundStyle(.secondary)
                            }
                            Text(shown.name).lineLimit(1).truncationMode(.middle)
                        }
                        .help("\(shown.name) (pid \(process.pid))")
                        Text(String(format: "%.1f%%", process.cpuPercent)).monospacedDigit()
                        Text(Format.bytes(process.memoryBytes)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            Text("CPU is a percentage of one core, like Activity Monitor. Shows your own processes; macOS needs admin rights to read others'.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
