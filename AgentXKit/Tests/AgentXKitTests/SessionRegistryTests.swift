import Darwin
import Foundation
import Testing
@testable import AgentXKit

@Suite("SessionRegistry")
struct SessionRegistryTests {
    private func fixtureDir(_ entries: [(pid: Int32, session: String, entrypoint: String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentx-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for e in entries {
            let json = #"{"pid": \#(e.pid), "sessionId": "\#(e.session)", "entrypoint": "\#(e.entrypoint)", "kind": "interactive"}"#
            try Data(json.utf8).write(to: dir.appendingPathComponent("\(e.pid).json"))
        }
        // Lock files sit next to the registry entries and must be ignored.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("\(getpid()).abc123.key"))
        return dir
    }

    @Test func listsLiveProcessesAndSkipsDeadOnes() throws {
        let dir = try fixtureDir([(getpid(), "live-session", "claude-desktop"), (999_999, "dead-session", "cli")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let owners = SessionRegistry.scan(in: dir, ownParents: [])
        #expect(owners["live-session"]?.first?.appName == "the Claude app")
        #expect(owners["dead-session"] == nil)
    }

    @Test func skipsProcessesStartedByAgentX() throws {
        let dir = try fixtureDir([(getpid(), "own-session", "sdk-ts")])
        defer { try? FileManager.default.removeItem(at: dir) }
        // This test process stands in for a Claude Code child of agent-core.
        #expect(SessionRegistry.scan(in: dir, ownParents: [getppid()]).isEmpty)
    }

    @Test func namesKnownApps() {
        #expect(ExternalSession(pid: 1, entrypoint: "cli").appName == "a terminal")
        #expect(ExternalSession(pid: 1, entrypoint: "claude-vscode").appName == "VS Code")
        #expect(ExternalSession(pid: 1, entrypoint: nil).appName == "another Claude Code window")
    }
}
