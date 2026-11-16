import EventKit
import Foundation

/// Calendar and Reminders through EventKit. macOS asks once for each, on first use.
actor CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    private func ensureAccess(to type: EKEntityType) async throws {
        let name = type == .event ? "Calendars" : "Reminders"
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted: Bool = try await withCheckedThrowingContinuation { cont in
                let done: @Sendable (Bool, (any Error)?) -> Void = { granted, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: granted) }
                }
                if type == .event { store.requestFullAccessToEvents(completion: done) }
                else { store.requestFullAccessToReminders(completion: done) }
            }
            if !granted { throw ToolError("You didn't allow access to \(name). Turn it on in System Settings › Privacy & Security › \(name) › AgentX.") }
        default:
            throw ToolError("AgentX doesn't have full access to \(name). Turn it on in System Settings › Privacy & Security › \(name) › AgentX.")
        }
    }

    func events(from start: Date, to end: Date, matching text: String?, calendar: String?) async throws -> String {
        try await ensureAccess(to: .event)
        let calendars = try calendar.map { [try findCalendar(named: $0, for: .event)] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        var events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if let text, !text.isEmpty {
            events = events.filter { ($0.title ?? "").localizedCaseInsensitiveContains(text) || ($0.location ?? "").localizedCaseInsensitiveContains(text) || ($0.notes ?? "").localizedCaseInsensitiveContains(text) }
        }
        guard !events.isEmpty else { return "No events between \(ToolDates.describe(start)) and \(ToolDates.describe(end))." }
        return events.prefix(60).map { e in
            var line = e.isAllDay ? "• \(ToolDates.describe(e.startDate, allDay: true)), all day: " : "• \(ToolDates.describe(e.startDate))–\(ToolDates.time(e.endDate)): "
            line += e.title ?? "(no title)"
            line += " [\(e.calendar.title)]"
            if let location = e.location, !location.isEmpty { line += " @ \(location)" }
            return line
        }.joined(separator: "\n")
    }

    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?, calendar: String?) async throws -> String {
        try await ensureAccess(to: .event)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.calendar = try calendar.map { try findCalendar(named: $0, for: .event) } ?? store.defaultCalendarForNewEvents
        guard event.calendar != nil else { throw ToolError("There's no default calendar to add events to.") }
        try store.save(event, span: .thisEvent, commit: true)
        return "Added \"\(title)\" on \(ToolDates.describe(start))–\(ToolDates.time(end)) to \(event.calendar.title)."
    }

    func reminders(list: String?, includeCompleted: Bool) async throws -> String {
        try await ensureAccess(to: .reminder)
        let calendars = try list.map { [try findCalendar(named: $0, for: .reminder)] }
        let predicate = includeCompleted
            ? store.predicateForReminders(in: calendars)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let lines: [String] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted {
                    ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                }
                cont.resume(returning: sorted.prefix(80).map { r in
                    var line = "• \(r.isCompleted ? "[done] " : "")\(r.title ?? "(no title)") [\(r.calendar.title)]"
                    if let due = r.dueDateComponents?.date { line += " due \(ToolDates.describe(due))" }
                    return line
                })
            }
        }
        return lines.isEmpty ? "No reminders\(list.map { " in \($0)" } ?? "")." : lines.joined(separator: "\n")
    }

    func createReminder(title: String, due: Date?, list: String?, notes: String?) async throws -> String {
        try await ensureAccess(to: .reminder)
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = try list.map { try findCalendar(named: $0, for: .reminder) } ?? store.defaultCalendarForNewReminders()
        guard reminder.calendar != nil else { throw ToolError("There's no default Reminders list.") }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return "Added reminder \"\(title)\"\(due.map { " for \(ToolDates.describe($0))" } ?? "") to \(reminder.calendar.title)."
    }

    func completeReminder(title: String) async throws -> String {
        try await ensureAccess(to: .reminder)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let ids: [String] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: (reminders ?? []).filter { ($0.title ?? "").localizedCaseInsensitiveContains(title) }.map(\.calendarItemIdentifier))
            }
        }
        guard ids.count == 1, let reminder = store.calendarItem(withIdentifier: ids[0]) as? EKReminder else {
            throw ToolError(ids.isEmpty ? "No open reminder matches \"\(title)\"." : "\(ids.count) open reminders match \"\(title)\". Use a more specific title.")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return "Marked \"\(reminder.title ?? title)\" as done."
    }

    private func findCalendar(named name: String, for type: EKEntityType) throws -> EKCalendar {
        let all = store.calendars(for: type)
        if let match = all.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        throw ToolError("No \(type == .event ? "calendar" : "Reminders list") named \"\(name)\". Available: \(all.map(\.title).joined(separator: ", ")).")
    }
}

enum CalendarTools {
    static var all: [MacTool] {[
        MacTool("calendar_events", area: "Calendar", summary: "List events", risk: .read,
                description: "List Calendar events in a time range (local time). Defaults to today. Use for questions like \"what's on my calendar\".",
                parameters: [
                    .init("start", .string, "Range start, local ISO 8601 (e.g. 2026-11-16T00:00). Defaults to the start of today.", required: false),
                    .init("end", .string, "Range end, local ISO 8601. Defaults to the end of the start day.", required: false),
                    .init("search", .string, "Only events whose title, location or notes contain this text.", required: false),
                    .init("calendar", .string, "Only this calendar (by name).", required: false),
                ]) { args in
            let start = try args.optionalDate("start") ?? Calendar.current.startOfDay(for: Date())
            let end = try args.optionalDate("end") ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start))!
            return try await CalendarService.shared.events(from: start, to: end, matching: args.optionalString("search"), calendar: args.optionalString("calendar"))
        },
        MacTool("calendar_create_event", area: "Calendar", summary: "Create an event", risk: .create,
                description: "Create a Calendar event. Give start and either end or durationMinutes (default 60).",
                parameters: [
                    .init("title", .string, "Event title."),
                    .init("start", .string, "Start, local ISO 8601 (e.g. 2026-11-17T15:00)."),
                    .init("end", .string, "End, local ISO 8601.", required: false),
                    .init("durationMinutes", .integer, "Length in minutes if no end is given.", required: false),
                    .init("location", .string, "Location.", required: false),
                    .init("notes", .string, "Notes.", required: false),
                    .init("calendar", .string, "Calendar name. Defaults to your default calendar.", required: false),
                ]) { args in
            let start = try args.date("start")
            let end = try args.optionalDate("end") ?? start.addingTimeInterval(TimeInterval(args.int("durationMinutes", default: 60) * 60))
            guard end > start else { throw ToolError("The end must be after the start.") }
            return try await CalendarService.shared.createEvent(title: args.string("title"), start: start, end: end,
                                                                 location: args.optionalString("location"), notes: args.optionalString("notes"),
                                                                 calendar: args.optionalString("calendar"))
        },
        MacTool("reminders_list", area: "Reminders", summary: "List reminders", risk: .read,
                description: "List open reminders (or all, including completed), sorted by due date.",
                parameters: [
                    .init("list", .string, "Only this Reminders list (by name).", required: false),
                    .init("includeCompleted", .boolean, "Include completed reminders.", required: false),
                ]) { args in
            try await CalendarService.shared.reminders(list: args.optionalString("list"), includeCompleted: args.bool("includeCompleted", default: false))
        },
        MacTool("reminders_create", area: "Reminders", summary: "Create a reminder", risk: .create,
                description: "Create a reminder, optionally with a due date and time (an alert fires then).",
                parameters: [
                    .init("title", .string, "What to be reminded of."),
                    .init("due", .string, "Due date/time, local ISO 8601.", required: false),
                    .init("list", .string, "Reminders list name. Defaults to your default list.", required: false),
                    .init("notes", .string, "Notes.", required: false),
                ]) { args in
            try await CalendarService.shared.createReminder(title: args.string("title"), due: args.optionalDate("due"),
                                                             list: args.optionalString("list"), notes: args.optionalString("notes"))
        },
        MacTool("reminders_complete", area: "Reminders", summary: "Mark a reminder done", risk: .ask,
                description: "Mark one open reminder as completed, found by (part of) its title.",
                parameters: [.init("title", .string, "Title of the reminder, or a unique part of it.")]) { args in
            try await CalendarService.shared.completeReminder(title: args.string("title"))
        },
    ]}
}
