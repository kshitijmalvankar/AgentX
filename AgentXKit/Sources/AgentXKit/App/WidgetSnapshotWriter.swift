import AgentXShared
import Foundation
import WidgetKit

/// Keeps the desktop widgets' data fresh: writes a snapshot every 15 minutes
/// and after important changes (at most once a minute), then asks macOS to
/// reload the widgets.
@MainActor
final class WidgetSnapshotWriter {
    private weak var model: AppModel?
    private let sampler = SystemSampler()   // separate from the System section's sampler
    private var loop: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var lastWrite: Date = .distantPast

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.write()
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    /// Something changed (an approval, a run, usage): write soon, at most once a minute.
    func setNeedsWrite() {
        guard pending == nil else { return }
        let wait = max(2, 60 - Date().timeIntervalSince(lastWrite))
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.pending = nil
            await self?.write()
        }
    }

    func write() async {
        guard let model else { return }
        lastWrite = Date()
        model.github.refreshIfStale(maxAge: 3600)

        // Two samples a second apart give a real CPU reading.
        _ = await sampler.sample()
        try? await Task.sleep(for: .seconds(1))
        let s = await sampler.sample()

        let snapshot = Self.compose(model: model, system: s)
        do {
            try snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Widgets keep their last data; nothing else depends on this file.
        }
    }

    static func compose(model: AppModel, system s: SystemSnapshot?) -> WidgetSnapshot {
        let live = model.sessions.liveConversations
        let usage = model.usage.usage?.windows.prefix(2).map {
            WidgetSnapshot.UsageWindow(label: $0.label, fraction: $0.fraction, resetsAt: $0.resetsAt)
        } ?? []
        let vitals = s.map {
            WidgetSnapshot.Vitals(cpu: $0.cpu, memoryUsed: $0.memory.used, memoryTotal: $0.memory.total,
                                  memoryPressure: $0.memoryPressure.label, diskFree: $0.disk.available, diskTotal: $0.disk.total,
                                  batteryLevel: $0.battery?.level, charging: $0.battery?.isCharging)
        }
        let github = model.github.snapshot.map { g in
            WidgetSnapshot.GitHub(login: g.profile.login, totalContributions: g.calendar.total,
                                  currentStreak: g.calendar.currentStreak, weeks: widgetWeeks(g.calendar, count: 20))
        }
        let next = model.automations.upcoming.first.map { WidgetSnapshot.NextAutomation(name: $0.automation.name, date: $0.date) }
        return WidgetSnapshot(
            planLabel: model.account?.account.planLabel,
            usage: usage,
            runningSessions: live.count,
            waitingApprovals: model.sessions.approvals.count,
            activity: live.prefix(3).map { .init(title: $0.title, state: $0.liveState?.label ?? "Ready") },
            vitals: vitals,
            github: github,
            nextAutomation: next
        )
    }

    /// The last `count` weeks as levels, with the first week padded so weekdays line up.
    static func widgetWeeks(_ calendar: ContributionCalendar, count: Int) -> [[Int]] {
        let weeks = calendar.weeks.suffix(count)
        return weeks.enumerated().map { index, week in
            let levels = week.map(\.level)
            guard index == 0, let first = week.first else { return levels }
            let pad = Calendar(identifier: .gregorian).component(.weekday, from: first.date) - 1
            return Array(repeating: -1, count: pad) + levels
        }
    }
}
