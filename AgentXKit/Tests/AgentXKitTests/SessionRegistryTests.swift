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

@Suite("Session modes and other apps")
struct SessionModeTests {
    @Test func modesIncludeAutoButNeverBypass() {
        #expect(PermissionModeOption.allCases.map(\.rawValue) == ["default", "acceptEdits", "plan", "auto"])
        #expect(PermissionModeOption(rawValue: "bypassPermissions") == nil, "skipping every check isn't offered")
        #expect(PermissionModeOption.auto.shortLabel == "Auto")
    }

    @Test func agentXProcessesAreNamed() {
        #expect(SessionRegistry.appName(ofPath: "/Users/me/Projects/AgentX/build/AgentX Dev.app/Contents/MacOS/AgentX Dev") == "AgentX Dev")
        #expect(SessionRegistry.appName(ofPath: "/Applications/AgentX.app/Contents/MacOS/AgentX") == "AgentX")
        #expect(SessionRegistry.appName(ofPath: "/Users/me/.nvm/versions/node/v24.13.0/bin/node") == nil)
        #expect(ExternalSession(pid: 1, entrypoint: "sdk-ts", hostApp: "AgentX Dev").appName == "AgentX Dev")
        #expect(ExternalSession(pid: 1, entrypoint: "sdk-ts").appName == "another Agent SDK app")
    }

    @Test func aQuitProcessIsNoticed() {
        #expect(!SessionRegistry.anyQuit([getpid()]))
        #expect(SessionRegistry.anyQuit([getpid(), 999_999]))
    }
}
