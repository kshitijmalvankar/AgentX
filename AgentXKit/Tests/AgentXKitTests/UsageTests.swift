import Foundation
import Testing
@testable import AgentXKit

@Suite("Plan usage")
struct PlanUsageTests {
    @Test func parsesWindowsFromClaudeCode() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"subscription_type":"pro","rate_limits_available":true,"rate_limits":{
          "five_hour":{"utilization":61,"resets_at":"2026-11-17T01:20:00.062719+00:00"},
          "seven_day":{"utilization":43,"resets_at":"2026-11-17T18:00:00.062766+00:00"},
          "seven_day_opus":null,"tangelo":null}}
        """#.utf8))
        let usage = try #require(UsageParser.parse(json))
        #expect(usage.plan == "pro")
        #expect(usage.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(abs(usage.session!.fraction - 0.61) < 0.0001)
        #expect(abs(usage.weekly!.fraction - 0.43) < 0.0001)
        #expect(usage.session?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-17T01:20:00Z"))
        #expect(usage.highest == 0.61)
    }

    @Test func noPlanLimitsMeansNoMeter() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}"#.utf8))
        #expect(UsageParser.parse(json) == nil)
    }
}
