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

/// A saved Claude task that runs on a schedule.
public struct Automation: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// With the Mac tools, in the assistant's folder.
        case assistant
        /// A Claude Code session in a project folder.
        case coding
        /// A briefing written on this Mac (Apple's on-device model) from your calendar,
        /// reminders and unread mail. No Claude: it doesn't use your plan.
        case onDevice
    }

    public var id = UUID()
    public var name: String
    public var prompt: String
    public var kind: Kind
    /// Project folder for coding automations.
    public var folder: String?
    public var schedule: AutomationSchedule
    public var enabled: Bool
    /// Extra Claude Code permission rules for unattended coding runs, e.g. "Bash(git status:*)".
    public var allowedTools: [String] = []
    public var createdAt = Date()
    /// When the schedule last fired (manual runs don't move it).
    public var lastScheduledAt: Date?
}

public struct AutomationRun: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, succeeded, failed, skipped }
    public enum Trigger: String, Codable, Sendable { case scheduled, manual, catchUp }

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
