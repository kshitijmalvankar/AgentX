import Darwin
import Foundation
import Testing
@testable import AgentXKit

@Suite("Child process environment")
struct ChildEnvironmentTests {
    @Test func dropsClaudeAndAnthropicVariables() {
        setenv("CLAUDE_CODE_SESSION_ID", "leaked-session", 1)
        setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:1", 1)
        setenv("CLAUDECODE", "1", 1)
        setenv("MCP_SERVER_CONNECTION_BATCH_SIZE", "4", 1)
        defer {
            for name in ["CLAUDE_CODE_SESSION_ID", "ANTHROPIC_BASE_URL", "CLAUDECODE", "MCP_SERVER_CONNECTION_BATCH_SIZE"] {
                unsetenv(name)
            }
        }

        let env = ToolLocator.baseEnvironment()
        #expect(env.keys.allSatisfy { !$0.hasPrefix("CLAUDE") && !$0.hasPrefix("ANTHROPIC") && !$0.hasPrefix("MCP_") })
        #expect(env["HOME"] == ProcessInfo.processInfo.environment["HOME"])
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
