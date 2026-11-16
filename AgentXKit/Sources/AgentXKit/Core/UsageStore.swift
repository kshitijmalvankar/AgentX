import Foundation
import Observation
import SwiftUI

/// One plan limit window, e.g. the 5-hour session or the weekly limit.
public struct UsageWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// 0…1
    public let fraction: Double
    public let resetsAt: Date?

    public var resetLabel: String? {
        guard let resetsAt else { return nil }
        let cal = Calendar.current
        let time = resetsAt.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(resetsAt) { return "resets \(time)" }
        if cal.isDateInTomorrow(resetsAt) { return "resets tomorrow \(time)" }
        return "resets \(resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }
}

/// Your Claude plan's usage, as Claude Code's /usage reports it.
public struct PlanUsage: Sendable, Equatable {
    public var plan: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Date

    public var session: UsageWindow? { windows.first { $0.id == "five_hour" } }
    public var weekly: UsageWindow? { windows.first { $0.id == "seven_day" } }
    /// The fullest window (what automations check before running).
    public var highest: Double? { windows.map(\.fraction).max() }
}

enum UsageParser {
    /// Windows worth showing, in display order.
    static let known: [(key: String, label: String)] = [
        ("five_hour", "Current session"),
        ("seven_day", "This week"),
        ("seven_day_opus", "This week · Opus"),
        ("seven_day_sonnet", "This week · Sonnet"),
    ]

    static func parse(_ json: JSONValue, now: Date = Date()) -> PlanUsage? {
        guard json["rate_limits_available"]?.bool == true, let limits = json["rate_limits"] else { return nil }
        let windows: [UsageWindow] = known.compactMap { key, label in
            guard let w = limits[key], let percent = w["utilization"]?.number else { return nil }
            return UsageWindow(id: key, label: label, fraction: min(1, max(0, percent / 100)),
                               resetsAt: w["resets_at"]?.string.flatMap(date))
        }
        return PlanUsage(plan: json["subscription_type"]?.string, windows: windows, fetchedAt: now)
    }

    /// ISO 8601 with any number of fractional digits ("2026-11-17T01:20:00.062719+00:00").
    static func date(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }
}

/// Refreshes plan usage every 10 minutes, and soon after each Claude reply.
@MainActor
@Observable
public final class UsageStore {
    public private(set) var usage: PlanUsage?
    public private(set) var unavailableReason: String?
    public private(set) var isRefreshing = false

    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored var onUpdate: (() -> Void)?

    init(client: AgentClient) {
        self.client = client
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Refresh shortly (coalesces bursts, e.g. several replies in a row).
    func refreshSoon(after delay: Duration = .seconds(20)) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    public func refresh() async {
        guard !isRefreshing, client.status == .ready else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let json = try await client.call("account.usage")
            if let parsed = UsageParser.parse(json) {
                usage = parsed
                unavailableReason = nil
            } else {
                unavailableReason = "Plan usage isn't available for this login (API keys don't have plan limits)."
            }
            onUpdate?()
        } catch {
            unavailableReason = error.localizedDescription
        }
    }
}

/// Bars for each plan window: "Current session 61% · resets 1:20".
struct UsageMeter: View {
    let usage: PlanUsage
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(compact ? Array(usage.windows.prefix(2)) : usage.windows) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(window.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.percent(window.fraction)).monospacedDigit()
                        if !compact, let reset = window.resetLabel { Text("· \(reset)").foregroundStyle(.secondary) }
                    }
                    .font(compact ? .caption : .callout)
                    CapacityBar(fraction: window.fraction, height: compact ? 6 : 8)
                    if compact, let reset = window.resetLabel {
                        Text(reset).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if let highest = usage.highest, highest >= 0.8 {
                StatusLabel(level: highest >= 0.95 ? .critical : .warning,
                            text: highest >= 0.95 ? "At your plan limit" : "Close to your plan limit")
            }
        }
    }
}
