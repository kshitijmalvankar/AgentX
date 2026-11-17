import Foundation

/// Whether AgentX may read Calendar or Reminders.
public enum CalendarAccess: Sendable, Equatable {
    case granted, notDetermined, denied
}

/// Events and open reminders for a stretch of time, as plain values. The
/// calendar_events tool and the dashboard's Today card both use it, so they
/// always agree.
public struct Agenda: Sendable, Equatable {
    public struct Event: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let start: Date
        public let end: Date
        public let isAllDay: Bool
        public let calendar: String
        public let color: RGB?
        public let location: String?
    }

    public struct Reminder: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// When it's due (nil: no due date).
        public let due: Date?
        /// False for reminders due on a day, without a time.
        public let hasTime: Bool
        public let list: String
        public let color: RGB?
        /// Due on an earlier day and still open.
        public let isOverdue: Bool
    }

    public struct RGB: Sendable, Equatable {
        public let red, green, blue: Double
    }

    public var start: Date
    public var end: Date
    public var events: [Event] = []
    /// Open reminders due in the range (and overdue ones, when the range starts today or earlier).
    public var reminders: [Reminder] = []
    public var eventsAccess: CalendarAccess = .granted
    public var remindersAccess: CalendarAccess = .granted

    public var isEmpty: Bool { events.isEmpty && reminders.isEmpty }

    /// The text Claude gets from calendar_events.
    public var text: String {
        var parts: [String] = []
        if eventsAccess == .granted {
            parts.append(events.isEmpty
                ? "No events between \(ToolDates.describe(start)) and \(ToolDates.describe(end))."
                : "Events:\n" + events.prefix(60).map(Self.line).joined(separator: "\n"))
        } else {
            parts.append("Events aren't included: AgentX doesn't have access to Calendar (System Settings › Privacy & Security › Calendars).")
        }
        switch remindersAccess {
        case .granted:
            parts.append(reminders.isEmpty
                ? "No open reminders due in that time."
                : "Reminders due:\n" + reminders.prefix(60).map(Self.line).joined(separator: "\n"))
        case .notDetermined, .denied:
            parts.append("Reminders aren't included: AgentX doesn't have access to Reminders (System Settings › Privacy & Security › Reminders).")
        }
        return parts.joined(separator: "\n\n")
    }

    static func line(_ e: Event) -> String {
        var line = e.isAllDay
            ? "• \(ToolDates.describe(e.start, allDay: true)), all day: "
            : "• \(ToolDates.describe(e.start))–\(ToolDates.time(e.end)): "
        line += e.title + " [\(e.calendar)]"
        if let location = e.location, !location.isEmpty { line += " @ \(location)" }
        return line
    }

    static func line(_ r: Reminder) -> String {
        var line = "• \(r.title) [\(r.list)]"
        if let due = r.due {
            line += r.isOverdue ? " overdue since " : " due "
            line += r.hasTime ? ToolDates.describe(due) : ToolDates.describe(due, allDay: true)
        }
        return line
    }

    /// A reminder's due date. EventKit's components usually have no calendar
    /// attached, so `DateComponents.date` would be nil; resolve them in the
    /// user's calendar instead.
    static func dueDate(_ components: DateComponents?, calendar: Calendar = .current) -> (date: Date, hasTime: Bool)? {
        guard let components, components.year != nil, components.month != nil, components.day != nil,
              let date = (components.calendar ?? calendar).date(from: components) else { return nil }
        return (date, components.hour != nil)
    }

    /// Due on a day before `today` (a reminder due earlier today isn't overdue).
    static func isOverdue(_ due: Date?, today: Date, calendar: Calendar = .current) -> Bool {
        guard let due else { return false }
        return due < calendar.startOfDay(for: today)
    }
}
