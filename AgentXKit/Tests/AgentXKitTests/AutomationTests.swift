import Foundation
import Testing
@testable import AgentXKit

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Dublin")!
    return c
}()

private func date(_ text: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: text)!
}

@Suite("Automation schedules")
struct AutomationScheduleTests {
    @Test func weekdaysSkipTheWeekend() {
        let weekdays = AutomationSchedule.daily(hour: 8, minute: 0, weekdays: [2, 3, 4, 5, 6])
        // Fri 20 Nov 2026 09:00 → Mon 23 Nov 08:00
        #expect(weekdays.nextRun(after: date("2026-11-20 09:00"), calendar: cal) == date("2026-11-23 08:00"))
        #expect(weekdays.nextRun(after: date("2026-11-23 07:59"), calendar: cal) == date("2026-11-23 08:00"))
        #expect(weekdays.label == "Weekdays at 8:00")
    }

    @Test func everyDayAndIntervals() {
        let evening = AutomationSchedule.daily(hour: 18, minute: 0, weekdays: [])
        #expect(evening.nextRun(after: date("2026-11-16 17:00"), calendar: cal) == date("2026-11-16 18:00"))
        #expect(evening.nextRun(after: date("2026-11-16 18:00"), calendar: cal) == date("2026-11-17 18:00"))
        #expect(AutomationSchedule.interval(hours: 3).nextRun(after: date("2026-11-16 10:00"), calendar: cal) == date("2026-11-16 13:00"))
        #expect(AutomationSchedule.daily(hour: 10, minute: 0, weekdays: [1]).nextRun(after: date("2026-11-16 12:00"), calendar: cal) == date("2026-11-22 10:00"))
    }

    @Test func dueRunsCatchUpOnceAndSkipLongGaps() {
        var a = Automation(name: "Brief", prompt: "x", kind: .assistant, folder: nil,
                           schedule: .daily(hour: 8, minute: 0, weekdays: []), enabled: true)
        a.lastScheduledAt = date("2026-11-16 07:00")
        #expect(AutomationTiming.dueAction(for: a, now: date("2026-11-16 07:30"), calendar: cal) == .wait(until: date("2026-11-16 08:00")))
        #expect(AutomationTiming.dueAction(for: a, now: date("2026-11-16 08:00"), calendar: cal) == .run(.scheduled))
        #expect(AutomationTiming.dueAction(for: a, now: date("2026-11-16 11:00"), calendar: cal) == .run(.catchUp))   // Mac slept until 11
        #expect(AutomationTiming.dueAction(for: a, now: date("2026-11-18 11:00"), calendar: cal) == .skipMissed)      // off for two days
    }
}

@Suite("Automation storage and runs")
@MainActor
struct AutomationCenterTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agentx-auto-\(UUID().uuidString)")
    }

    @Test func startersArriveTurnedOffAndEditsPersist() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = AutomationCenter(directory: dir)
        #expect(center.automations.map(\.name) == ["Morning brief", "Repo check", "Tidy Downloads"])
        #expect(center.automations.allSatisfy { !$0.enabled })
        #expect(center.upcoming.isEmpty)

        let brief = center.automations[0]
        center.setEnabled(brief.id, true)
        let enabled = try #require(center.automations.first { $0.id == brief.id })
        #expect(enabled.enabled)
        #expect(abs(enabled.lastScheduledAt!.timeIntervalSinceNow) < 5, "turning on starts the schedule from now")

        let reloaded = AutomationCenter(directory: dir)
        #expect(reloaded.automations.first { $0.id == brief.id }?.enabled == true)
        #expect(reloaded.upcoming.count == 1)
    }

    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "agentx-tests-\(UUID().uuidString)")!
    }

    @Test func longMissedRunsAreRecordedAsSkipped() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = AutomationCenter(directory: dir, defaults: freshDefaults(), pausedByDefault: false)
        var a = center.automations[1]
        a.enabled = true
        center.update(a)
        // Pretend the schedule last fired three days ago.
        var stale = try #require(center.automations.first { $0.id == a.id })
        stale.lastScheduledAt = Date().addingTimeInterval(-3 * 86_400)
        center.update(stale)
        center.tick(now: Date())
        let run = try #require(center.runs.first)
        #expect(run.status == .skipped && run.automationName == "Repo check")
    }

    @Test func pausedAutomationsSkipQuietlyWithoutCatchUp() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = freshDefaults()
        let center = AutomationCenter(directory: dir, defaults: defaults, pausedByDefault: true)
        #expect(center.isPaused, "AgentX Dev starts with automations paused")
        var a = center.automations[0]
        a.enabled = true
        center.update(a)
        var due = try #require(center.automations.first { $0.id == a.id })
        due.lastScheduledAt = Date().addingTimeInterval(-2 * 86_400)
        center.update(due)
        center.tick(now: Date())
        #expect(center.runs.isEmpty, "nothing runs while paused")
        let after = try #require(center.automations.first { $0.id == a.id })
        #expect(abs(after.lastScheduledAt!.timeIntervalSinceNow) < 5, "the missed run is skipped, so resuming doesn't set off a catch-up")

        center.isPaused = false
        #expect(AutomationCenter(directory: dir, defaults: defaults, pausedByDefault: true).isPaused == false, "the choice is remembered")
    }

    @Test func unansweredApprovalsInUnattendedRunsAreDenied() async throws {
        let store = SessionStore(client: AgentClient())
        store.unattendedApprovalTimeout = .milliseconds(200)
        var timedOut = false
        store.onApprovalTimedOut = { _ in timedOut = true }
        let c = Conversation(id: "auto-1", kind: .assistant, sessionId: "s1", cwd: "/tmp", title: "Tidy Downloads · Sun 10:00")
        c.liveHandle = "h1"
        c.automationRunID = UUID()
        store.insert(c)

        let answer = try await store.handleRequest("permission.request",
                                                   params: ["handle": "h1", "toolName": "mcp__agentx__files_move", "input": [:]],
                                                   id: "core-7")
        #expect(answer["behavior"]?.string == "deny")
        #expect(answer["message"]?.string?.contains("No answer") == true)
        #expect(timedOut)
        #expect(store.approvals.isEmpty)
    }
}

@Suite("Automation, live")
@MainActor
struct AutomationLiveTests {
    /// AGENTX_LIVE_AUTOMATION=1 AGENTX_CORE_PATH=…/agent-core swift test --filter AutomationLive
    /// Runs one tiny automation end to end through the real engine (uses a few tokens of your plan).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTX_LIVE_AUTOMATION"] != nil))
    func runsEndToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentx-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = AgentClient()
        await client.start()
        await client.waitUntilReady()
        #expect(client.status == .ready)
        let store = SessionStore(client: client)
        let center = AutomationCenter(directory: dir)
        center.sessions = store
        store.onTurnFinished = { c, result in center.turnFinished(c, result: result) }
        client.notificationHandler = { method, params in store.handleNotification(method, params: params) }

        let job = Automation(name: "Ping", prompt: "Reply with exactly the word: pong", kind: .assistant, folder: nil,
                             schedule: .interval(hours: 24), enabled: false)
        center.add(job)
        center.runNow(job)
        for _ in 0..<240 where center.runs.first?.status ?? .running == .running { try await Task.sleep(for: .milliseconds(500)) }
        let run = try #require(center.runs.first)
        print("=== automation live: \(run.status.rawValue) · \(run.summary ?? "-") · session \(run.sessionId != nil)")
        #expect(run.status == .succeeded)
        #expect(run.summary?.lowercased().contains("pong") == true)
        #expect(run.sessionId != nil)
        client.stop()
    }
}
