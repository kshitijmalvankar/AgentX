import AppKit
import Foundation
import Observation

/// Saves automations, runs them on schedule while AgentX is running, and
/// keeps their run history.
@MainActor
@Observable
public final class AutomationCenter {
    /// A run that takes longer than this is stopped.
    public static let runTimeout: Duration = .seconds(20 * 60)
    /// Runs are skipped when plan usage is at or above this fraction.
    public static let usageCeiling = 0.9

    public private(set) var automations: [Automation] = []
    /// Newest first, at most 200.
    public private(set) var runs: [AutomationRun] = []
    public private(set) var storageError: String?

    @ObservationIgnored weak var sessions: SessionStore?
    /// Latest plan usage, 0…1 (set by AppModel).
    @ObservationIgnored var planUsage: @MainActor () -> Double? = { nil }
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Automation id → its run in progress.
    @ObservationIgnored private var active: [UUID: (runID: UUID, timeout: Task<Void, Never>)] = [:]
    /// Called after every save (e.g. to update the widgets).
    @ObservationIgnored var onChange: (() -> Void)?

    /// While paused, scheduled runs are skipped (manual "Run now" still works).
    /// AgentX Dev starts paused so it doesn't run your automations twice.
    public var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Self.pausedKey) }
    }
    static let pausedKey = "automationsPaused"
    @ObservationIgnored private let defaults: UserDefaults

    public init(directory: URL = AppChannel.current.dataDirectory, defaults: UserDefaults = .standard,
                pausedByDefault: Bool = AppChannel.current.isDev) {
        self.directory = directory
        self.defaults = defaults
        defaults.register(defaults: [Self.pausedKey: pausedByDefault])
        isPaused = defaults.bool(forKey: Self.pausedKey)
        load()
    }

    // MARK: Storage

    private var automationsFile: URL { directory.appendingPathComponent("automations.json") }
    private var runsFile: URL { directory.appendingPathComponent("automation-runs.json") }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: automationsFile) {
            do { automations = try decoder.decode([Automation].self, from: data) }
            catch { storageError = "Couldn't read automations.json: \(error.localizedDescription)" }
        } else {
            automations = AutomationTemplates.all   // first launch: the starters, turned off
            save()
        }
        if let data = try? Data(contentsOf: runsFile), let saved = try? decoder.decode([AutomationRun].self, from: data) {
            // A run still marked running belongs to an earlier launch.
            runs = saved.map { run in
                guard run.status == .running else { return run }
                var r = run
                r.status = .failed
                r.summary = "AgentX quit before this run finished."
                return r
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try SecureFile.write(encoder.encode(automations), to: automationsFile)
            try SecureFile.write(encoder.encode(Array(runs.prefix(200))), to: runsFile)
            storageError = nil
            onChange?()
        } catch {
            storageError = "Couldn't save automations: \(error.localizedDescription)"
        }
    }

    // MARK: Editing

    public func add(_ automation: Automation) {
        var a = automation
        a.lastScheduledAt = Date()
        automations.append(a)
        save()
    }

    public func update(_ automation: Automation) {
        guard let i = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        var a = automation
        if a.schedule != automations[i].schedule || (a.enabled && !automations[i].enabled) { a.lastScheduledAt = Date() }
        automations[i] = a
        save()
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard var a = automations.first(where: { $0.id == id }) else { return }
        a.enabled = enabled
        update(a)
    }

    public func delete(_ id: UUID) {
        automations.removeAll { $0.id == id }
        save()
    }

    public func isRunning(_ id: UUID) -> Bool { active[id] != nil }

    /// When it will run next (nil if it's off).
    public func nextRun(of automation: Automation) -> Date? {
        guard automation.enabled else { return nil }
        return automation.schedule.nextRun(after: automation.lastScheduledAt ?? automation.createdAt)
    }

    public var upcoming: [(automation: Automation, date: Date)] {
        automations.compactMap { a in nextRun(of: a).map { (a, $0) } }.sorted { $0.date < $1.date }
    }

    public func lastRun(of automation: Automation) -> AutomationRun? {
        runs.first { $0.automationID == automation.id }
    }

    // MARK: Scheduling

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // Catch up right after the Mac wakes (give the network a moment).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self?.tick()
            }
        }
    }

    func tick(now: Date = Date()) {
        for automation in automations where automation.enabled && active[automation.id] == nil {
            let due = AutomationTiming.dueAction(for: automation, now: now)
            if isPaused {
                // Skip it rather than queue it: resuming shouldn't set off a burst of catch-up runs.
                if case .wait = due { continue }
                markFired(automation.id, at: now)
                continue
            }
            switch due {
            case .wait:
                continue
            case .run(let trigger):
                markFired(automation.id, at: now)
                Task { await run(automation, trigger: trigger) }
            case .skipMissed:
                markFired(automation.id, at: now)
                record(skipped: automation, reason: "Missed while the Mac was off or AgentX wasn't running.")
            }
        }
    }

    private func markFired(_ id: UUID, at date: Date) {
        guard let i = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[i].lastScheduledAt = date
        save()
    }

    // MARK: Running

    public func runNow(_ automation: Automation) {
        Task { await run(automation, trigger: .manual) }
    }

    private func run(_ automation: Automation, trigger: AutomationRun.Trigger) async {
        guard let sessions, active[automation.id] == nil else { return }
        if let usage = planUsage(), usage >= Self.usageCeiling {
            record(skipped: automation, reason: "Skipped: your Claude plan usage is at \(Format.percent(usage)).")
            return
        }
        let run = AutomationRun(automationID: automation.id, automationName: automation.name, trigger: trigger)
        runs.insert(run, at: 0)
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.runTimeout)
            guard !Task.isCancelled else { return }
            await self?.timedOut(automation.id)
        }
        active[automation.id] = (run.id, timeout)
        save()

        let cwd = automation.kind == .coding ? (automation.folder ?? NSHomeDirectory()) : AssistantWorkspace.path
        let c = await sessions.startAutomationRun(
            kind: automation.kind == .coding ? .coding : .assistant,
            cwd: cwd,
            prompt: automation.prompt,
            title: "\(automation.name) · \(run.startedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))",
            runID: run.id,
            instructions: Self.instructions(for: automation),
            allowedTools: automation.allowedTools
        )
        updateRun(run.id) { $0.cwd = cwd }
        if c.liveHandle == nil, let error = c.error {
            finish(automation.id, status: .failed, summary: error, sessionId: nil)
        }
    }

    static func instructions(for automation: Automation) -> String {
        """
        This is an unattended, scheduled run of the AgentX automation "\(automation.name)". The user isn't watching.
        - Anything that needs approval is sent to the user as a notification; if they don't answer within 10 minutes it is denied. If something is denied, carry on without it and mention it in your summary.
        - Finish with a short summary (at most 6 lines) of what you found or did. It's shown as a notification and on the AgentX dashboard.
        """
    }

    /// Called when a run's Claude Code turn ends.
    func turnFinished(_ c: Conversation, result: JSONValue) {
        guard let runID = c.automationRunID,
              let automationID = active.first(where: { $0.value.runID == runID })?.key else { return }
        let isError = result["is_error"]?.bool ?? false
        let summary = c.lastAssistantText ?? (isError ? "The run stopped with an error." : "Finished.")
        finish(automationID, status: isError ? .failed : .succeeded, summary: summary, sessionId: c.sessionId)
        Task { await sessions?.stop(c) }   // free the Claude Code process; the transcript stays on disk
    }

    /// An approval in an unattended run went unanswered and was denied.
    func approvalUnanswered(_ c: Conversation) {
        guard let runID = c.automationRunID else { return }
        updateRun(runID) { $0.unansweredApprovals += 1 }
        save()
    }

    private func timedOut(_ automationID: UUID) async {
        guard let runID = active[automationID]?.runID else { return }
        if let c = sessions?.conversations.values.first(where: { $0.automationRunID == runID }) {
            await sessions?.stop(c)
        }
        finish(automationID, status: .failed, summary: "Took longer than 20 minutes and was stopped.", sessionId: nil)
    }

    private func finish(_ automationID: UUID, status: AutomationRun.Status, summary: String, sessionId: String?) {
        guard let entry = active.removeValue(forKey: automationID) else { return }
        entry.timeout.cancel()
        updateRun(entry.runID) {
            $0.status = status
            $0.summary = summary
            $0.finishedAt = Date()
            if let sessionId { $0.sessionId = sessionId }
        }
        save()
        if let run = runs.first(where: { $0.id == entry.runID }) { NotificationManager.shared.postAutomationResult(run) }
    }

    private func record(skipped automation: Automation, reason: String) {
        var run = AutomationRun(automationID: automation.id, automationName: automation.name, trigger: .scheduled)
        run.status = .skipped
        run.summary = reason
        run.finishedAt = Date()
        runs.insert(run, at: 0)
        save()
    }

    private func updateRun(_ id: UUID, _ change: (inout AutomationRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[i])
    }
}
