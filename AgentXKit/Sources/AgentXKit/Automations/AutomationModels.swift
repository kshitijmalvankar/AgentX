import Foundation

/// When an automation runs.
public enum AutomationSchedule: Codable, Equatable, Sendable {
    /// At a time of day, on some weekdays (1 = Sunday … 7 = Saturday; empty = every day).
    case daily(hour: Int, minute: Int, weekdays: Set<Int>)
    /// Every N hours, counted from the last scheduled run.
    case interval(hours: Int)

    /// The first scheduled time strictly after `date`.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .interval(let hours):
            return date.addingTimeInterval(TimeInterval(max(1, hours) * 3600))
        case .daily(let hour, let minute, let weekdays):
            var day = calendar.startOfDay(for: date)
            for _ in 0..<8 {
                if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                   candidate > date,
                   weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: candidate)) {
                    return candidate
                }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            return date.addingTimeInterval(86_400)
        }
    }

    public var label: String {
        switch self {
        case .interval(let hours):
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        case .daily(let hour, let minute, let weekdays):
            let time = String(format: "%d:%02d", hour, minute)
            switch weekdays {
            case []: return "Every day at \(time)"
            case [2, 3, 4, 5, 6]: return "Weekdays at \(time)"
            case [1, 7]: return "Weekends at \(time)"
            default:
                let names = Calendar.current.shortWeekdaySymbols
                let days = weekdays.sorted().map { names[$0 - 1] }
                return days.count == 1 ? "\(Calendar.current.weekdaySymbols[weekdays.first! - 1])s at \(time)" : "\(days.joined(separator: ", ")) at \(time)"
            }
        }
    }
}

/// What starts an automation instead of its schedule: something happening on
/// your Mac, in your calendar, mail or GitHub (TriggerEngine watches for it).
public enum AutomationTrigger: Codable, Equatable, Hashable, Sendable {
    /// A new file appears in a folder; `pattern` limits it to names like "*.pdf" (several: "*.pdf, *.png").
    case fileAdded(folder: String, pattern: String?)
    /// A timed calendar event starts in `minutesBefore` minutes; optionally only titles containing some text.
    case calendarEventSoon(minutesBefore: Int, titleContains: String?)
    /// An app opens.
    case appLaunched(bundleID: String, name: String)
    /// The Mac wakes from sleep.
    case macWoke
    /// You unlock the Mac for the first time today.
    case firstUnlockOfDay
    /// The power cable goes in.
    case powerConnected
    /// The battery drops below a level while on battery.
    case batteryBelow(percent: Int)
    /// New unread mail in Mail from a sender whose name or address contains the text.
    case mailFrom(sender: String)
    /// Someone asks for your review on a GitHub pull request.
    case reviewRequested
    /// Checks fail on one of your open pull requests.
    case checksFailed

    public var label: String {
        switch self {
        case .fileAdded(let folder, let pattern):
            let place = (folder as NSString).lastPathComponent
            if let pattern, !pattern.isEmpty { return "When \(pattern) is added to \(place)" }
            return "When a file is added to \(place)"
        case .calendarEventSoon(let minutes, let title):
            let what = title.map { "“\($0)”" } ?? "an event"
            return "\(minutes) min before \(what)"
        case .appLaunched(_, let name): return "When \(name) opens"
        case .macWoke: return "When the Mac wakes"
        case .firstUnlockOfDay: return "First unlock of the day"
        case .powerConnected: return "When plugged in"
        case .batteryBelow(let percent): return "When the battery drops below \(percent)%"
        case .mailFrom(let sender): return "When mail arrives from \(sender)"
        case .reviewRequested: return "When your review is requested on GitHub"
        case .checksFailed: return "When checks fail on your pull request"
        }
    }

    public var symbol: String {
        switch self {
        case .fileAdded: "folder.badge.plus"
        case .calendarEventSoon: "calendar.badge.clock"
        case .appLaunched: "app.badge"
        case .macWoke: "sun.max"
        case .firstUnlockOfDay: "lock.open"
        case .powerConnected: "powerplug"
        case .batteryBelow: "battery.25percent"
        case .mailFrom: "envelope.badge"
        case .reviewRequested: "person.crop.circle.badge.questionmark"
        case .checksFailed: "xmark.octagon"
        }
    }
}

/// A saved task that runs on a schedule, or when something happens.
public struct Automation: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// With the Mac tools, in the assistant's folder.
        case assistant
        /// A Claude Code session in a project folder.
        case coding
        /// A briefing written on this Mac (Apple's on-device model) from your calendar,
        /// reminders and unread mail. No Claude: it doesn't use your plan.
        case onDevice
        /// Just a notification saying what happened (and your note). No Claude, no model.
        case notify
    }

    public var id = UUID()
    public var name: String
    public var prompt: String
    public var kind: Kind
    /// Project folder for coding automations.
    public var folder: String?
    public var schedule: AutomationSchedule
    /// Runs when this happens instead of on `schedule` (nil: on the schedule).
    public var trigger: AutomationTrigger?
    /// Triggered Claude runs: Apple's on-device model checks the event first and starts Claude only when it fits.
    public var checkFirst: Bool?
    /// What the check looks for ("the email asks me to do something"). Empty: whether the task has anything to do.
    public var condition: String?
    public var enabled: Bool
    /// Extra Claude Code permission rules for unattended coding runs, e.g. "Bash(git status:*)".
    public var allowedTools: [String] = []
    public var createdAt = Date()
    /// When the schedule last fired (manual runs don't move it).
    public var lastScheduledAt: Date?

    /// "Weekdays at 8:00", or "When a file is added to Downloads".
    public var whenLabel: String { trigger?.label ?? schedule.label }

    /// Whether a triggered run asks Apple's on-device model before starting Claude.
    public var checksOnMacFirst: Bool { checkFirst == true && trigger != nil && (kind == .assistant || kind == .coding) }
}

public struct AutomationRun: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, succeeded, failed, skipped }
    public enum Trigger: String, Codable, Sendable { case scheduled, manual, catchUp, event }

    public var id = UUID()
    public var automationID: UUID
    public var automationName: String
    public var trigger: Trigger
    public var startedAt = Date()
    public var finishedAt: Date?
    public var status: Status = .running
    /// Claude's closing summary, or why it failed or was skipped.
    public var summary: String?
    public var sessionId: String?
    public var cwd: String?
    /// Approvals nobody answered in time (denied automatically).
    public var unansweredApprovals = 0
    /// What set it off, for runs started by a trigger ("report.pdf was added to Downloads").
    public var event: String?
    /// How many events the check on this Mac found didn't need Claude (today's are counted in one entry).
    public var checkedOnMac: Int?
}

/// What the scheduler should do about one automation right now.
enum DueAction: Equatable {
    case wait(until: Date)
    case run(AutomationRun.Trigger)
    /// Missed by more than the catch-up window (e.g. the Mac was off for days).
    case skipMissed
}

enum AutomationTiming {
    /// A run missed while the Mac slept still happens once on wake, if it's this recent.
    static let catchUpWindow: TimeInterval = 12 * 3600

    static func dueAction(for automation: Automation, now: Date, calendar: Calendar = .current) -> DueAction {
        let anchor = automation.lastScheduledAt ?? automation.createdAt
        let due = automation.schedule.nextRun(after: anchor, calendar: calendar)
        guard due <= now else { return .wait(until: due) }
        let late = now.timeIntervalSince(due)
        if late < 120 { return .run(.scheduled) }
        return late <= catchUpWindow ? .run(.catchUp) : .skipMissed
    }
}

/// The starter automations (added turned off).
enum AutomationTemplates {
    /// Starters that run when something happens (added once, turned off, for people who already have automations).
    static var triggered: [Automation] {[
        Automation(
            name: "Meeting prep",
            prompt: "A meeting starts soon (details below). Look for related notes, recent emails with the people in it, and files that mention it. Give me a short prep: what it's about, what's still open, and anything I should bring up.",
            kind: .assistant, folder: nil, schedule: .daily(hour: 9, minute: 0, weekdays: []),
            trigger: .calendarEventSoon(minutesBefore: 10, titleContains: nil), enabled: false),
        Automation(
            name: "Downloads sorter",
            prompt: "A new file arrived in Downloads (below). In one or two lines, suggest where it belongs and why. Only if a folder clearly fits, move it with files_move, so I can approve the move.",
            kind: .assistant, folder: nil, schedule: .daily(hour: 9, minute: 0, weekdays: []),
            trigger: .fileAdded(folder: NSHomeDirectory() + "/Downloads", pattern: nil), enabled: false),
        Automation(
            name: "PR review nudge",
            prompt: "Someone is waiting for your review.",
            kind: .notify, folder: nil, schedule: .daily(hour: 9, minute: 0, weekdays: []),
            trigger: .reviewRequested, enabled: false),
        Automation(
            name: "Low battery",
            prompt: "Plug in soon, or save your work.",
            kind: .notify, folder: nil, schedule: .daily(hour: 9, minute: 0, weekdays: []),
            trigger: .batteryBelow(percent: 20), enabled: false),
        Automation(
            name: "Welcome back",
            prompt: "",
            kind: .onDevice, folder: nil, schedule: .daily(hour: 9, minute: 0, weekdays: []),
            trigger: .firstUnlockOfDay, enabled: false),
    ]}

    static var all: [Automation] {[
        Automation(
            name: "Morning brief",
            prompt: "Give me my morning brief: today's calendar events, reminders due today or overdue, and unread email (who it's from and whether it needs a reply). Keep it short and easy to scan.",
            kind: .assistant, folder: nil,
            schedule: .daily(hour: 8, minute: 0, weekdays: [2, 3, 4, 5, 6]), enabled: false),
        Automation(
            name: "Repo check",
            prompt: "Check my code repositories with repos_status. List any with uncommitted changes, commits to push, or that are behind, and suggest what to do about each. If everything is clean, say so in one line.",
            kind: .assistant, folder: nil,
            schedule: .daily(hour: 18, minute: 0, weekdays: []), enabled: false),
        Automation(
            name: "Tidy Downloads",
            prompt: "Look through my ~/Downloads folder. Suggest a tidy-up: group files into sensible folders, and point out old installers, duplicates and big files. Only move files one at a time with files_move, so I can approve each move.",
            kind: .assistant, folder: nil,
            schedule: .daily(hour: 10, minute: 0, weekdays: [1]), enabled: false),
    ]}
}
