import Foundation

/// Something a trigger source noticed (TriggerSources.swift).
enum TriggerSignal: Equatable, Sendable {
    case fileAdded(folder: String, path: String)
    /// A timed event starting at `start` (the calendar source reports each one every minute until it starts).
    case eventSoon(id: String, title: String, start: Date, location: String?, attendees: [String])
    case appLaunched(bundleID: String, name: String)
    case macWoke
    case unlocked
    /// The power state now (sent when it changes, and once a minute).
    case power(onAC: Bool, percent: Int?)
    case mail(id: String, sender: String, subject: String)
    case reviewRequested(GitHubPullRequest)
    case checksFailed(GitHubPullRequest)
}

/// What set an automation off.
struct TriggerEvent: Equatable, Sendable {
    /// The same happening (a file, a meeting, a pull request) has the same key, and fires once.
    var key: String
    /// One line for you: the run history and notifications.
    var summary: String
    /// For Claude. It comes from outside AgentX (file names, event titles, mail subjects,
    /// pull request titles), so the run treats it as data, never as instructions.
    var details: String
}

/// Whether a signal sets off a trigger, and as what event. No side effects (tested).
enum TriggerMatch {
    static func event(for trigger: AutomationTrigger, _ signal: TriggerSignal, now: Date = Date(),
                       calendar: Calendar = .current) -> TriggerEvent? {
        switch (trigger, signal) {
        case let (.fileAdded(folder, pattern), .fileAdded(signalFolder, path)):
            guard standardized(folder) == standardized(signalFolder) else { return nil }
            let name = (path as NSString).lastPathComponent
            guard FileTriggers.matches(name, pattern: pattern) else { return nil }
            return TriggerEvent(key: "file:\(path)",
                                summary: "\(name) was added to \((folder as NSString).lastPathComponent)",
                                details: "A new file was added: \(path)")

        case let (.calendarEventSoon(minutesBefore, titleContains), .eventSoon(id, title, start, location, attendees)):
            let secondsLeft = start.timeIntervalSince(now)
            guard secondsLeft > 0, secondsLeft <= Double(minutesBefore) * 60 else { return nil }
            if let filter = titleContains?.trimmingCharacters(in: .whitespaces), !filter.isEmpty,
               !title.localizedCaseInsensitiveContains(filter) { return nil }
            let minutes = max(1, Int((secondsLeft / 60).rounded()))
            var lines = ["Event: \(title)", "Starts: \(start.formatted(date: .abbreviated, time: .shortened))"]
            if let location, !location.isEmpty { lines.append("Location: \(location)") }
            if !attendees.isEmpty { lines.append("With: \(attendees.prefix(12).joined(separator: ", "))") }
            return TriggerEvent(key: "calendar:\(id):\(Int(start.timeIntervalSince1970))",
                                summary: "\(title) starts in \(minutes) min",
                                details: lines.joined(separator: "\n"))

        case let (.appLaunched(bundleID, _), .appLaunched(signalID, name)):
            guard bundleID.caseInsensitiveCompare(signalID) == .orderedSame else { return nil }
            // Opening the same app again within a minute is the same opening.
            return TriggerEvent(key: "app:\(signalID):\(Int(now.timeIntervalSince1970 / 60))",
                                summary: "\(name) opened", details: "The app \(name) (\(signalID)) was opened.")

        case (.macWoke, .macWoke):
            return TriggerEvent(key: "wake:\(Int(now.timeIntervalSince1970 / 60))",
                                summary: "The Mac woke up", details: "The Mac woke from sleep.")

        case (.firstUnlockOfDay, .unlocked):
            let day = calendar.dateComponents([.year, .month, .day], from: now)
            return TriggerEvent(key: "unlock:\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)",
                                summary: "First unlock today", details: "The user unlocked the Mac for the first time today.")

        case let (.mailFrom(sender), .mail(id, from, subject)):
            let wanted = sender.trimmingCharacters(in: .whitespaces)
            guard !wanted.isEmpty, from.localizedCaseInsensitiveContains(wanted) else { return nil }
            return TriggerEvent(key: "mail:\(id)", summary: "Mail from \(from): \(subject)",
                                details: "New unread mail in Mail.\nFrom: \(from)\nSubject: \(subject)")

        case let (.reviewRequested, .reviewRequested(pr)):
            return TriggerEvent(key: "review:\(pr.url.absoluteString)",
                                summary: "\(pr.author.map { "\($0) asked" } ?? "You were asked") for your review on \(pr.repoName) #\(pr.number)",
                                details: pullRequestDetails(pr))

        case let (.checksFailed, .checksFailed(pr)):
            return TriggerEvent(key: "checks:\(pr.url.absoluteString):\(Int((pr.updatedAt ?? now).timeIntervalSince1970))",
                                summary: "Checks failed on \(pr.repoName) #\(pr.number)", details: pullRequestDetails(pr))

        default:
            // Plugged in and battery low need the reading before (BatteryWatch).
            return nil
        }
    }

    private static func pullRequestDetails(_ pr: GitHubPullRequest) -> String {
        var lines = ["Pull request: \(pr.title)", "Repository: \(pr.repo) #\(pr.number)", "URL: \(pr.url.absoluteString)"]
        if let author = pr.author { lines.append("Author: \(author)") }
        return lines.joined(separator: "\n")
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path.lowercased()
    }
}

/// Plugged in, and battery-low, from successive power readings (tested).
struct BatteryWatch: Equatable {
    private var lastOnAC: Bool?
    /// Levels already reported since the battery was last above them (or on power).
    private var reported: Set<Int> = []

    /// What this reading sets off: plugged in, and each battery level it has just dropped below.
    mutating func update(onAC: Bool, percent: Int?, thresholds: Set<Int>, now: Date = Date())
        -> (pluggedIn: TriggerEvent?, below: [Int: TriggerEvent]) {
        var plugged: TriggerEvent?
        if lastOnAC == false, onAC {
            plugged = TriggerEvent(key: "power:\(Int(now.timeIntervalSince1970))", summary: "The Mac was plugged in",
                                   details: "The power cable was connected\(percent.map { " at \($0)% battery" } ?? "").")
        }
        lastOnAC = onAC
        var below: [Int: TriggerEvent] = [:]
        if let percent {
            for threshold in thresholds {
                if onAC || percent >= threshold {
                    reported.remove(threshold)
                } else if !reported.contains(threshold) {
                    reported.insert(threshold)
                    below[threshold] = TriggerEvent(key: "battery:\(threshold):\(Int(now.timeIntervalSince1970 / 60))",
                                                    summary: "Battery is at \(percent)%",
                                                    details: "The battery dropped to \(percent)% and the Mac isn't plugged in.")
                }
            }
        }
        return (plugged, below)
    }
}

/// Keeps triggered runs in check: each happening fires once, an automation runs at
/// most once every 10 minutes, and at most 20 triggered runs a day (tested).
struct TriggerGate: Codable, Equatable {
    static let cooldown: TimeInterval = 10 * 60
    static let dailyLimit = 20

    enum Decision: Equatable { case fire, duplicate, paused, coolingDown, dailyLimit }

    /// Event key → when it was seen (kept a week).
    private(set) var seen: [String: Date] = [:]
    private(set) var lastFired: [UUID: Date] = [:]
    private(set) var firedAt: [Date] = []

    mutating func decide(_ automation: UUID, key: String, paused: Bool, now: Date = Date()) -> Decision {
        seen = seen.filter { now.timeIntervalSince($0.value) < 7 * 86_400 }
        firedAt = firedAt.filter { now.timeIntervalSince($0) < 86_400 }
        let seenKey = "\(automation.uuidString)|\(key)"
        if seen[seenKey] != nil { return .duplicate }
        // Every happening counts as seen, even one that's skipped: it never fires later.
        seen[seenKey] = now
        if paused { return .paused }
        if let last = lastFired[automation], now.timeIntervalSince(last) < Self.cooldown { return .coolingDown }
        if firedAt.count >= Self.dailyLimit { return .dailyLimit }
        lastFired[automation] = now
        firedAt.append(now)
        return .fire
    }
}

/// File names a folder trigger cares about.
enum FileTriggers {
    /// Downloads in progress and hidden files never count.
    static func isIgnored(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".") || lower.hasPrefix("~$")
            || [".download", ".crdownload", ".part", ".partial", ".tmp", ".icloud"].contains { lower.hasSuffix($0) }
    }

    /// `pattern`: "*.pdf", or several separated by commas or spaces. Empty: every file.
    static func matches(_ name: String, pattern: String?) -> Bool {
        guard !isIgnored(name) else { return false }
        let patterns = (pattern ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.lowercased() }
        guard !patterns.isEmpty else { return true }
        return patterns.contains { fnmatch($0, name.lowercased(), 0) == 0 }
    }

    /// Names in `now` that weren't in `before`, and count.
    static func added(before: Set<String>, now: Set<String>) -> [String] {
        now.subtracting(before).filter { !isIgnored($0) }.sorted()
    }
}

/// Watches for what your automations' triggers need, only while an enabled
/// automation needs it, and starts the automation when it happens.
@MainActor
final class TriggerEngine {
    weak var center: AutomationCenter?
    weak var github: GitHubStore?
    private var sources: [String: TriggerSource] = [:]
    private var gate: TriggerGate
    private var battery = BatteryWatch()
    private let stateFile: URL

    init(stateFile: URL = AppChannel.current.dataFile("trigger-state.json")) {
        self.stateFile = stateFile
        gate = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(TriggerGate.self, from: $0) } ?? TriggerGate()
    }

    private var triggered: [Automation] {
        center?.automations.filter { $0.enabled && $0.trigger != nil } ?? []
    }

    /// Start the sources enabled automations need, and stop the rest. Called on start and after every change.
    func update() {
        var needed: [String: () -> TriggerSource] = [:]
        var folders = Set<String>()
        var maxMinutes = 0
        for automation in triggered {
            switch automation.trigger {
            case .fileAdded(let folder, _): folders.insert((folder as NSString).expandingTildeInPath)
            case .calendarEventSoon(let minutes, _): maxMinutes = max(maxMinutes, minutes)
            case .appLaunched: needed["apps"] = { AppLaunchSource() }
            case .macWoke, .firstUnlockOfDay: needed["mac"] = { MacStateSource() }
            case .powerConnected, .batteryBelow: needed["power"] = { PowerSource() }
            case .mailFrom: needed["mail"] = { MailSource() }
            case .reviewRequested, .checksFailed:
                let github = github
                needed["github"] = { GitHubSource(store: github) }
            case nil: break
            }
        }
        if !folders.isEmpty {
            let list = folders.sorted()
            needed["files:" + list.joined(separator: "|")] = { FolderSource(folders: list) }
        }
        if maxMinutes > 0 { needed["calendar:\(maxMinutes)"] = { CalendarSource(lookAheadMinutes: maxMinutes) } }

        for (key, source) in sources where needed[key] == nil {
            source.stop()
            sources[key] = nil
        }
        for (key, make) in needed where sources[key] == nil {
            let source = make()
            sources[key] = source
            source.start { [weak self] signal in self?.received(signal) }
        }
    }

    func stopAll() {
        sources.values.forEach { $0.stop() }
        sources = [:]
    }

    /// Which sources are running (for tests and the Automations view).
    var runningSources: [String] { sources.keys.sorted() }

    func received(_ signal: TriggerSignal, now: Date = Date()) {
        let automations = triggered
        // A power reading is read once, for every power and battery trigger.
        var power: (pluggedIn: TriggerEvent?, below: [Int: TriggerEvent])?
        if case let .power(onAC, percent) = signal {
            let thresholds = Set(automations.compactMap { a -> Int? in
                if case .batteryBelow(let p) = a.trigger { p } else { nil }
            })
            power = battery.update(onAC: onAC, percent: percent, thresholds: thresholds, now: now)
        }
        for automation in automations {
            guard let trigger = automation.trigger else { continue }
            let event: TriggerEvent?
            if let power {
                switch trigger {
                case .powerConnected: event = power.pluggedIn
                case .batteryBelow(let p): event = power.below[p]
                default: event = nil
                }
            } else {
                event = TriggerMatch.event(for: trigger, signal, now: now)
            }
            if let event { consider(automation, event, now: now) }
        }
    }

    private func consider(_ automation: Automation, _ event: TriggerEvent, now: Date) {
        guard let center else { return }
        let decision = gate.decide(automation.id, key: event.key, paused: center.isPaused, now: now)
        save()
        switch decision {
        case .fire:
            center.fire(automation, event: event)
        case .dailyLimit:
            center.recordSkipped(automation, event: event,
                                 reason: "Skipped: \(TriggerGate.dailyLimit) runs started by triggers today is the limit.")
        case .duplicate, .paused, .coolingDown:
            break
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(gate) else { return }
        try? SecureFile.write(data, to: stateFile)
    }
}
