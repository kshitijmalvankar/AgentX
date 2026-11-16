import Foundation
import Testing
@testable import AgentXKit

@Suite("Engine performance")
@MainActor
struct EnginePerformanceTests {
    @Test func fastParserMatchesCodable() throws {
        let samples = [
            #"{"a":true,"b":false,"c":0,"d":1,"e":2.5,"f":"ünïcødé ✓","g":null,"h":[1,"x",{"i":[]}],"j":{}}"#,
            #"[{"type":"text","text":"line\nbreak \"quoted\""},{"type":"tool_use","input":{"n":-3}}]"#,
            #""just a string""#, "42", "true", "null",
        ]
        for s in samples {
            let data = Data(s.utf8)
            #expect(try JSONValue.parse(data) == JSONDecoder().decode(JSONValue.self, from: data), "\(s)")
        }
    }

    @Test func toolPathsAreCached() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentx-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("core/src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); UserDefaults.standard.removeObject(forKey: "cachedToolPaths") }
        let node = dir.appendingPathComponent("node")
        try "#!/bin/sh\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        try "".write(to: dir.appendingPathComponent("core/src/index.ts"), atomically: true, encoding: .utf8)
        let paths = ToolPaths(node: node.path, claude: nil, agentCore: dir.appendingPathComponent("core").path, shellPath: "/usr/bin:/bin")
        ToolLocator.remember(paths)
        #expect(ToolLocator.cached() == paths)
        try FileManager.default.removeItem(at: node)
        #expect(ToolLocator.cached() == nil, "a cache pointing at a missing program is ignored")
    }
}

@Suite("Engine startup timing")
@MainActor
struct EngineStartupTimingTests {
    /// AGENTX_PERF_ENGINE=1 AGENTX_CORE_PATH=…/agent-core swift test --filter EngineStartupTiming
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTX_PERF_ENGINE"] != nil))
    func coldVersusCachedStartup() async {
        UserDefaults.standard.removeObject(forKey: "cachedToolPaths")
        var results: [String] = []
        for label in ["without cache", "with cache"] {
            let client = AgentClient()
            let start = ContinuousClock.now
            await client.start()
            await client.waitUntilReady()
            results.append("\(label): \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])))")
            #expect(client.status == .ready)
            client.stop()
            try? await Task.sleep(for: .milliseconds(300))
        }
        print("=== engine ready · " + results.joined(separator: " · "))
        UserDefaults.standard.removeObject(forKey: "cachedToolPaths")
    }
}
