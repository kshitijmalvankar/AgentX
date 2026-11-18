import Foundation
import Testing
@testable import AgentXKit

@Suite("Connected tools")
struct ConnectorToolTests {
    @Test func connectorNamesReadNicely() {
        #expect(SecuritySettings.displayName(ofTool: "mcp__claude_ai_Google_Calendar__list_events") == "Google Calendar · list events")
        #expect(SecuritySettings.displayName(ofTool: "WebFetch") == "WebFetch")
    }
}
