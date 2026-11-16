// AgentX desktop widgets. They read the snapshot AgentX writes to
// ~/Library/Application Support/AgentX/widget-snapshot.json (every 15
// minutes, and after important changes) and never talk to Claude or GitHub.
import AgentXShared
import SwiftUI
import WidgetKit

@main
struct AgentXWidgets: WidgetBundle {
    var body: some Widget {
        ClaudeWidget()
        VitalsWidget()
        GitHubWidget()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// nil until AgentX has written its first snapshot.
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .preview : (WidgetSnapshot.load() ?? .preview)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

// MARK: - Claude

struct ClaudeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeWidget", provider: SnapshotProvider()) { entry in
            ClaudeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "agentx://dashboard"))
        }
        .configurationDisplayName("Claude")
        .description("Your plan usage, what Claude is working on, and approvals waiting for you.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ClaudeWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    usage(s)
                    Divider()
                    activity(s)
                }
            } else {
                usage(s)
            }
        } else {
            NoDataView()
        }
    }

    private func usage(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(symbol: "sparkles", title: s.planLabel ?? "Claude")
            status(s)
            Spacer(minLength: 2)
            if s.usage.isEmpty {
                Text("Usage appears once AgentX has checked your plan.").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(s.usage.enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(window.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(percent(window.fraction)).font(.caption2.monospacedDigit())
                    }
                    Bar(fraction: window.fraction)
                }
            }
        }
    }

    @ViewBuilder private func status(_ s: WidgetSnapshot) -> some View {
        if s.waitingApprovals > 0 {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(s.waitingApprovals) waiting for you")
            }
            .font(.caption.weight(.medium))
        } else {
            Text(s.runningSessions == 0 ? "Nothing running" : "\(s.runningSessions) running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func activity(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if s.activity.isEmpty {
                Text("No sessions running.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(s.activity.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.caption).lineLimit(1)
                    Text(item.state).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let next = s.nextAutomation {
                Label("\(next.name) · \(next.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Mac vitals

struct VitalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VitalsWidget", provider: SnapshotProvider()) { entry in
            VitalsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "agentx://system"))
        }
        .configurationDisplayName("Mac Vitals")
        .description("CPU, memory, battery and disk, from AgentX.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct VitalsWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot, let v = s.vitals {
            VStack(alignment: .leading, spacing: 6) {
                Header(symbol: "gauge.with.dots.needle.50percent", title: "Mac Vitals")
                let rows = [
                    row("cpu", "CPU", percent(v.cpu), v.cpu),
                    row("memorychip", "Memory", family == .systemMedium ? "\(bytes(v.memoryUsed)) of \(bytes(v.memoryTotal))" : percent(Double(v.memoryUsed) / Double(max(1, v.memoryTotal))),
                        Double(v.memoryUsed) / Double(max(1, v.memoryTotal))),
                    row("internaldrive", "Disk", "\(bytes(v.diskFree)) free", 1 - Double(v.diskFree) / Double(max(1, v.diskTotal))),
                ] + (v.batteryLevel.map { [row(v.charging == true ? "battery.100percent.bolt" : "battery.75percent", "Battery", percent($0), $0)] } ?? [])
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in r }
                Spacer(minLength: 0)
                HStack {
                    if v.memoryPressure != "Normal" {
                        Label("\(v.memoryPressure) memory pressure", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(s.updatedAt, format: .dateTime.hour().minute()).foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }
        } else {
            NoDataView()
        }
    }

    private func row(_ symbol: String, _ name: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol).frame(width: 14).foregroundStyle(.secondary)
                Text(name).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(value).monospacedDigit().lineLimit(1)
            }
            .font(.caption)
            if family == .systemMedium { Bar(fraction: fraction) }
        }
    }
}

// MARK: - GitHub

struct GitHubWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GitHubWidget", provider: SnapshotProvider()) { entry in
            GitHubWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "agentx://github"))
        }
        .configurationDisplayName("GitHub Activity")
        .description("Your contribution calendar and streak.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct GitHubWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let g = entry.snapshot?.github {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Header(symbol: "chevron.left.forwardslash.chevron.right", title: "@\(g.login)")
                    Spacer()
                    if family == .systemMedium {
                        Text("\(g.totalContributions) this year").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                grid(family == .systemMedium ? g.weeks : Array(g.weeks.suffix(8)), cell: family == .systemMedium ? 11 : 10)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("\(g.currentStreak)").font(.title3.weight(.semibold)).monospacedDigit()
                    Text("day streak").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if entry.snapshot != nil {
            VStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.title2).foregroundStyle(.secondary)
                Text("Open GitHub in AgentX to connect.").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        } else {
            NoDataView()
        }
    }

    private func grid(_ weeks: [[Int]], cell: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 2.5) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 2.5) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level < 0 ? Color.clear : green(level))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }

    /// GitHub's contribution greens.
    private func green(_ level: Int) -> Color {
        let light: [UInt32] = [0xEBEDF0, 0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
        let dark: [UInt32] = [0x2D333B, 0x0E4429, 0x006D32, 0x26A641, 0x39D353]
        let hex = (scheme == .dark ? dark : light)[min(4, max(0, level))]
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Shared pieces

private struct Header: View {
    let symbol: String
    let title: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
    }
}

private struct Bar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.accentColor).frame(width: max(3, min(1, fraction) * geo.size.width))
            }
        }
        .frame(height: 5)
    }
}

private struct NoDataView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
            Text("Open AgentX to start").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}
