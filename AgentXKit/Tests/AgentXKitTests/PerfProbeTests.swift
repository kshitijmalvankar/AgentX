import Foundation
import Testing
@testable import AgentXKit

/// AGENTX_PERF=/path/to/session.jsonl swift test --filter PerfProbe   (prints timings only)
@Suite("Perf probe")
struct PerfProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTX_PERF"] != nil))
    func decodeTranscript() throws {
        let path = ProcessInfo.processInfo.environment["AGENTX_PERF"]!
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
        let bytes = lines.reduce(0) { $0 + $1.count }
        let clock = ContinuousClock()
        let codable = clock.measure { for l in lines { _ = try? JSONDecoder().decode(JSONValue.self, from: l) } }
        let fast = clock.measure { for l in lines { _ = try? JSONValue.parse(l) } }
        print("=== perf: \(lines.count) lines, \(bytes / 1_048_576) MB · Codable JSONValue: \(codable) · JSONSerialization: \(fast)")
        // Both paths must agree.
        for l in lines.prefix(300) { #expect(try JSONValue.parse(l) == JSONDecoder().decode(JSONValue.self, from: l)) }
    }
}
