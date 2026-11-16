import Foundation
import Testing
@testable import AgentXKit

@Suite("TerminalStore")
@MainActor
struct TerminalStoreTests {
    @Test func tracksExitAndPhoneSync() async throws {
        let store = TerminalStore()
        let session = store.start(id: "t1", executable: "/bin/sh", arguments: ["-c", "exit 3"],
                                  directory: NSTemporaryDirectory(), environment: ToolLocator.baseEnvironment(),
                                  remoteControl: true)
        #expect(store.remoteControlled.map(\.id) == ["t1"])
        for _ in 0..<50 where session.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        #expect(session.exitCode == .some(3))
        #expect(store.remoteControlled.isEmpty)
        store.stop("t1")
        #expect(store.session(for: "t1") == nil)
    }
}
