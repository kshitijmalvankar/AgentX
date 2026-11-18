import AppKit
import EventKit
import SwiftUI

/// Today's events and the reminders due (or overdue), for the dashboard.
/// Refreshes when Calendar or Reminders change and when the day rolls over.
@MainActor
@Observable
public final class TodayAgenda {
    public private(set) var agenda: Agenda?
    /// One line about the day, written on this Mac ("Busy morning, free after 2. Dentist at 4.").
    public private(set) var summary: String?
    @ObservationIgnored private var summarized = ""
    /// Reminders you ticked off on the card (this session), so you can undo.
    public private(set) var completed: [Agenda.Reminder] = []
    public var lastError: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Start keeping it current (called when the card first appears).
    func start() {
        guard observers.isEmpty else { return }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        observers = [
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main, using: refresh),
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: refresh),
        ]
    }

    func refresh() async {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        agenda = try? await CalendarService.shared.agenda(from: today, to: tomorrow, prompt: false)
        await summarize()
    }

    /// Sum the day up on this Mac (Apple's on-device model), when the agenda changed.
    private func summarize() async {
        guard let agenda, !agenda.isEmpty, LocalCommands.shared.isAvailable else { summary = nil; return }
        let lines = Self.describe(agenda)
        guard lines != summarized else { return }
        summarized = lines
        summary = await LocalBriefing.dayLine(from: lines)
    }

    /// The day as plain lines for the model: times and titles only.
    nonisolated static func describe(_ agenda: Agenda) -> String {
        let events = agenda.events.map { e in
            e.isAllDay ? "All day: \(e.title)" : "\(e.start.formatted(.dateTime.hour().minute()))–\(e.end.formatted(.dateTime.hour().minute())): \(e.title)"
        }
        let reminders = agenda.reminders.map { r in
            "To do\(r.due.map { $0 < Date() && r.isOverdue ? " (overdue)" : r.hasTime ? " at \($0.formatted(.dateTime.hour().minute()))" : "" } ?? ""): \(r.title)"
        }
        return (events + reminders).joined(separator: "\n")
    }

    /// Tick a reminder off from the card.
    func complete(_ reminder: Agenda.Reminder) async {
        do {
            try await CalendarService.shared.setCompleted(reminder.id, true)
            completed.removeAll { $0.id == reminder.id }
            completed.insert(reminder, at: 0)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Put a ticked-off reminder back.
    func undo(_ reminder: Agenda.Reminder) async {
        do {
            try await CalendarService.shared.setCompleted(reminder.id, false)
            completed.removeAll { $0.id == reminder.id }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// The card's "Show my agenda" button: macOS asks for Calendar and Reminders.
    func requestAccess() async {
        await CalendarService.shared.requestAccess()
        await refresh()
    }
}

/// Dashboard card: today's events and reminders.
struct TodayCard: View {
    @Environment(AppModel.self) private var model
    private var today: TodayAgenda { model.today }
    private static let shown = 5

    var body: some View {
        GlassCard("Today", symbol: "calendar", tint: .red) {
            Button("Calendar") { open("/System/Applications/Calendar.app") }.buttonStyle(.link)
        } content: {
            if let summary = today.summary {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            if let agenda = today.agenda {
                content(agenda)
            } else {
                Text("Reading your calendar…").foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 140)
        .task {
            today.start()
            await today.refresh()
        }
    }

    @ViewBuilder private func content(_ agenda: Agenda) -> some View {
        let needsAccess = agenda.eventsAccess == .notDetermined || agenda.remindersAccess == .notDetermined
        let denied = agenda.eventsAccess == .denied || agenda.remindersAccess == .denied

        if agenda.eventsAccess == .granted || agenda.remindersAccess == .granted {
            if agenda.isEmpty {
                Text("Nothing scheduled today.").foregroundStyle(.secondary)
            }
            if !agenda.events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agenda.events.prefix(Self.shown)) { EventRow(event: $0) }
                    more(agenda.events.count, "event")
                }
            }
            if !agenda.reminders.isEmpty || !today.completed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agenda.reminders.prefix(Self.shown)) { reminder in
                        ReminderRow(reminder: reminder, done: false) { Task { await today.complete(reminder) } }
                    }
                    more(agenda.reminders.count, "reminder")
                    // Ticked off here: shown done (click to undo) until AgentX quits.
                    ForEach(today.completed.prefix(3)) { reminder in
                        ReminderRow(reminder: reminder, done: true) { Task { await today.undo(reminder) } }
                    }
                }
            }
            if let error = today.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }

        if needsAccess {
            HStack {
                Text(agenda.eventsAccess == .granted ? "Show reminders here too?" : "See today's events and reminders here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show My Agenda") { Task { await today.requestAccess() } }
                    .secondaryButton()
                    .controlSize(.small)
                    .help("macOS asks once whether AgentX may read Calendar and Reminders.")
            }
        } else if denied {
            HStack {
                Text(agenda.eventsAccess == .denied ? "AgentX can't read Calendar." : "AgentX can't read Reminders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Privacy Settings") {
                    let pane = agenda.eventsAccess == .denied ? "Privacy_Calendars" : "Privacy_Reminders"
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .secondaryButton()
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func more(_ count: Int, _ noun: String) -> some View {
        if count > Self.shown {
            Text("+\(count - Self.shown) more \(noun)\(count - Self.shown == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func open(_ app: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app))
    }
}

private struct EventRow: View {
    let event: Agenda.Event
    @State private var showDetails = false

    var body: some View {
        Button { showDetails = true } label: { row }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails, arrowEdge: .trailing) { EventDetails(event: event) }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.hour().minute()))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(event.color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .accentColor)
                .frame(width: 3, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).lineLimit(1)
                if let location = event.location, !location.isEmpty {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(.rect)
        .help("\(event.title) · \(event.calendar). Click for details.")
    }
}

/// A reminder: the circle ticks it off (or, once done, puts it back); the
/// rest of the row shows its details.
private struct ReminderRow: View {
    let reminder: Agenda.Reminder
    let done: Bool
    let toggle: () -> Void
    @State private var showDetails = false

    private var tint: Color { reminder.color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .accentColor }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(tint)
                    .frame(width: 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(done ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(done ? "Mark \(reminder.title) as not done" : "Mark \(reminder.title) as done")

            Button { showDetails = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reminder.title)
                        .lineLimit(1)
                        .strikethrough(done)
                        .foregroundStyle(done ? .secondary : .primary)
                    Spacer(minLength: 4)
                    if let due = reminder.due, !done {
                        Text(label(due))
                            .font(.caption)
                            .foregroundStyle(reminder.isOverdue ? Color.red : Color.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Click for details")
            .popover(isPresented: $showDetails, arrowEdge: .trailing) { ReminderDetails(reminder: reminder, done: done, toggle: toggle) }
        }
        .font(.callout)
    }

    private func label(_ due: Date) -> String {
        if reminder.isOverdue { return "Overdue · " + due.formatted(.dateTime.day().month(.abbreviated)) }
        return reminder.hasTime ? due.formatted(.dateTime.hour().minute()) : "Today"
    }
}

private struct EventDetails: View {
    let event: Agenda.Event

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.title).font(.headline)
            Label(time, systemImage: "clock")
            Label(event.calendar, systemImage: "calendar")
            if let location = event.location, !location.isEmpty { Label(location, systemImage: "mappin.and.ellipse") }
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                ScrollView { Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 160)
            }
            Button("Open Calendar") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
                .secondaryButton()
                .controlSize(.small)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private var time: String {
        if event.isAllDay { return "All day" }
        return "\(event.start.formatted(.dateTime.hour().minute()))–\(event.end.formatted(.dateTime.hour().minute()))"
    }
}

private struct ReminderDetails: View {
    let reminder: Agenda.Reminder
    let done: Bool
    let toggle: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reminder.title).font(.headline).strikethrough(done)
            if let due = reminder.due {
                Label(reminder.hasTime ? due.formatted(.dateTime.weekday(.wide).day().month().hour().minute())
                                       : due.formatted(.dateTime.weekday(.wide).day().month()),
                      systemImage: "calendar.badge.clock")
                    .foregroundStyle(reminder.isOverdue && !done ? .red : .primary)
            }
            Label(reminder.list, systemImage: "list.bullet")
            if let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                ScrollView { Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 160)
            }
            HStack {
                Button(done ? "Mark as Not Done" : "Mark as Done", systemImage: done ? "arrow.uturn.backward" : "checkmark") {
                    toggle()
                    dismiss()
                }
                .primaryButton()
                Button("Open Reminders") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app")) }
                    .secondaryButton()
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}
