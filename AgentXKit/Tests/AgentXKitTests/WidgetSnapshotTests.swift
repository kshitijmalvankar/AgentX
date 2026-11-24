import AgentXShared
import Foundation
import Testing
@testable import AgentXKit

@Suite("Widget snapshot")
@MainActor
struct WidgetSnapshotTests {
    @Test func roundTripsThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentx-widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try WidgetSnapshot.preview.save(to: url)
        let loaded = try #require(WidgetSnapshot.load(from: url))
        #expect(loaded.usage.count == 2 && loaded.github?.weeks.count == 20)
        #expect(abs(loaded.updatedAt.timeIntervalSince(WidgetSnapshot.preview.updatedAt)) < 1)
        #expect(WidgetSnapshot.fileURL.path.hasSuffix("Library/Application Support/AgentX/widget-snapshot.json"))
        #expect(!WidgetSnapshot.realHome.contains("/Containers/"))
    }

    @Test func padsThePartialFirstWeek() throws {
        // The calendar starts on a Wednesday (2026-11-11): three empty slots before it.
        var builder: [[ContributionDay]] = [[]]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        for (i, day) in ["2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14"].enumerated() {
            builder[0].append(ContributionDay(day: day, date: f.date(from: day)!, count: i, level: i))
        }
        let weeks = WidgetSnapshotWriter.widgetWeeks(ContributionCalendar(total: 6, weeks: builder), count: 20)
        #expect(weeks == [[-1, -1, -1, 0, 1, 2, 3]])
    }

    @Test func composesFromAnEmptyApp() {
        // Its own folders, so the test never touches AgentX Dev's real automations or activity log.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentx-widget-\(UUID().uuidString)")
        let scratch = ScratchDefaults()
        defer { try? FileManager.default.removeItem(at: dir); scratch.remove() }
        let model = AppModel(activity: ActivityLog(fileURL: dir.appendingPathComponent("activity.jsonl")),
                             automations: AutomationCenter(directory: dir, defaults: scratch.defaults))
        let snapshot = WidgetSnapshotWriter.compose(model: model, system: nil)
        #expect(snapshot.runningSessions == 0 && snapshot.waitingApprovals == 0)
        #expect(snapshot.github == nil && snapshot.vitals == nil)
    }
}

@Suite("Dashboard card grid")
struct CardGridTests {
    @Test func rowsFillTheWidthWithoutLoneCards() {
        let grid = CardGrid(minimum: 340, spacing: 16)
        #expect(grid.columns(for: 1100, count: 2) == 2, "two cards share a wide row")
        #expect(grid.columns(for: 1100, count: 4) == 2, "four cards: two rows of two, not three and one")
        #expect(grid.columns(for: 1100, count: 3) == 3)
        #expect(grid.columns(for: 1100, count: 5) == 3, "three and two is fine")
        #expect(grid.columns(for: 600, count: 4) == 1, "narrow: one column")
        #expect(grid.columns(for: 700, count: 4) == 2)
    }
}
