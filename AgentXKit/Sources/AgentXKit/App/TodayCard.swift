import AppKit
import EventKit
import SwiftUI

/// Today's events and the reminders due (or overdue), for the dashboard.
/// Refreshes when Calendar or Reminders change and when the day rolls over.
@MainActor
@Observable
public final class TodayAgenda {
    public private(set) var agenda: Agenda?
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
        GlassCard("Today", symbol: "calendar") {
            Button("Calendar") { open("/System/Applications/Calendar.app") }.buttonStyle(.link)
        } content: {
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
            if !agenda.reminders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agenda.reminders.prefix(Self.shown)) { reminder in
                        Button { open("/System/Applications/Reminders.app") } label: { ReminderRow(reminder: reminder) }
                            .buttonStyle(.plain)
                            .help("Open Reminders")
                    }
                    more(agenda.reminders.count, "reminder")
                }
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

    var body: some View {
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
        .help("\(event.title) · \(event.calendar)")
    }
}

private struct ReminderRow: View {
    let reminder: Agenda.Reminder

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle")
                .foregroundStyle(reminder.color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .accentColor)
                .frame(width: 14)
            Text(reminder.title).lineLimit(1)
            Spacer(minLength: 4)
            if let due = reminder.due {
                Text(label(due))
                    .font(.caption)
                    .foregroundStyle(reminder.isOverdue ? Color.red : Color.secondary)
            }
        }
        .font(.callout)
        .contentShape(.rect)
    }

    private func label(_ due: Date) -> String {
        if reminder.isOverdue { return "Overdue · " + due.formatted(.dateTime.day().month(.abbreviated)) }
        return reminder.hasTime ? due.formatted(.dateTime.hour().minute()) : "Today"
    }
}
