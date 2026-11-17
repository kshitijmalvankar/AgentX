import Foundation
import Testing
@testable import AgentXKit

@Suite("Agenda (calendar_events and the Today card)")
struct AgendaTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Dublin")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func dueDatesWithoutACalendarStillResolve() throws {
        // What EventKit hands back for "Call Jayu, today": no calendar in the components.
        let dayOnly = DateComponents(year: 2026, month: 11, day: 17)
        #expect(dayOnly.date == nil, "this is why due dates went missing before")
        let resolved = try #require(Agenda.dueDate(dayOnly, calendar: cal))
        #expect(resolved.date == date(2026, 11, 17))
        #expect(resolved.hasTime == false)

        let timed = try #require(Agenda.dueDate(DateComponents(year: 2026, month: 11, day: 17, hour: 15, minute: 30), calendar: cal))
        #expect(timed.date == date(2026, 11, 17, 15, 30))
        #expect(timed.hasTime)
        #expect(Agenda.dueDate(nil) == nil)
        #expect(Agenda.dueDate(DateComponents(hour: 9)) == nil)
    }

    @Test func onlyEarlierDaysCountAsOverdue() {
        let now = date(2026, 11, 17, 16, 0)
        #expect(Agenda.isOverdue(date(2026, 11, 16, 9), today: now, calendar: cal))
        #expect(!Agenda.isOverdue(date(2026, 11, 17, 9), today: now, calendar: cal), "earlier today is still today")
        #expect(!Agenda.isOverdue(date(2026, 11, 17), today: now, calendar: cal))
        #expect(!Agenda.isOverdue(nil, today: now, calendar: cal))
    }

    @Test func claudeSeesRemindersNextToEvents() {
        var agenda = Agenda(start: date(2026, 11, 17), end: date(2026, 11, 18))
        agenda.reminders = [
            .init(id: "r1", title: "Call Jayu", due: date(2026, 11, 17), hasTime: false, list: "Reminders", color: nil, isOverdue: false),
            .init(id: "r2", title: "Pay rent", due: date(2026, 11, 15, 9), hasTime: true, list: "Home", color: nil, isOverdue: true),
        ]
        let text = agenda.text
        #expect(text.contains("No events between"))
        #expect(text.contains("Reminders due:\n• Call Jayu [Reminders] due "))
        #expect(text.contains("• Pay rent [Home] overdue since "))
        #expect(!agenda.isEmpty)
    }

    @Test func missingRemindersAccessIsSaidNotHidden() {
        var agenda = Agenda(start: date(2026, 11, 17), end: date(2026, 11, 18))
        agenda.remindersAccess = .denied
        #expect(agenda.text.contains("Reminders aren't included"))
        agenda.eventsAccess = .notDetermined
        #expect(agenda.text.contains("Events aren't included"))
    }

    @Test func calendarToolSaysItIncludesReminders() throws {
        let tool = try #require(MacToolbox.tool(named: "calendar_events"))
        #expect(tool.description.contains("reminders"))
        #expect(tool.risk == .read)
    }
}

@Suite("Automation permission")
struct AutomationAccessTests {
    @Test func scriptsKnowWhichAppTheyNeed() {
        #expect(AutomationTarget.of(script: "on run argv\n tell application \"Mail\"\n  get inbox\n end tell\nend run") == .mail)
        #expect(AutomationTarget.of(script: "tell application \"Notes\" to make new note") == .notes)
        #expect(AutomationTarget.of(script: "tell application \"Messages\" to send x") == .messages)
        #expect(AutomationTarget.of(script: "tell application \"System Events\" to tell appearance preferences to set dark mode to true") == .systemEvents)
        #expect(AutomationTarget.of(script: "set volume output volume 30") == nil, "no app to ask about")
        #expect(AutomationTarget.of(script: "tell application \"Safari\" to get URL of current tab of front window") == .safari)
        #expect(AutomationTarget.of(script: "tell application \"Google Chrome\" to get URL of active tab of front window") == .chrome)
        #expect(AutomationTarget.of(script: "tell application \"Music\" to play") == nil)
    }

    @Test func remindersCarryTheirNotes() {
        let r = Agenda.Reminder(id: "r", title: "Call Jayu", due: nil, hasTime: false, list: "Reminders", color: nil,
                                isOverdue: false, notes: "About the trip")
        #expect(r.notes == "About the trip")
    }
}
