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
        let snapshot = WidgetSnapshotWriter.compose(model: AppModel(), system: nil)
        #expect(snapshot.runningSessions == 0 && snapshot.waitingApprovals == 0)
        #expect(snapshot.github == nil && snapshot.vitals == nil)
    }
}
