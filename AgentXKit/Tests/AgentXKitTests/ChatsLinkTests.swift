import Foundation
import Testing
@testable import AgentXKit

@Suite("Chats link rules")
struct ChatsLinkTests {
    @Test func claudeHostsStayInApp() {
        #expect(ClaudeWebController.isClaude("claude.ai"))
        #expect(ClaudeWebController.isClaude("www.claude.ai"))
        #expect(ClaudeWebController.isClaude("support.anthropic.com"))
        #expect(!ClaudeWebController.isClaude("claude.ai.example.com"))
        #expect(!ClaudeWebController.isClaude("notclaude.ai"))
        #expect(ClaudeWebController.isAllowedInApp("appleid.apple.com"))
        #expect(!ClaudeWebController.isAllowedInApp("github.com"))
    }

    @Test func codePagesBelongInSessions() {
        #expect(ClaudeWebController.isCodePage(URL(string: "https://claude.ai/code")!))
        #expect(ClaudeWebController.isCodePage(URL(string: "https://claude.ai/code/session_123?x=1")!))
        #expect(!ClaudeWebController.isCodePage(URL(string: "https://claude.ai/chat/abc")!))
        #expect(!ClaudeWebController.isCodePage(URL(string: "https://claude.ai/codex")!))
        #expect(!ClaudeWebController.isCodePage(URL(string: "https://github.com/code/x")!))
    }

    @Test func detectsGoogleSignIn() {
        #expect(ClaudeWebController.isGoogleSignIn(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=x")!))
        #expect(!ClaudeWebController.isGoogleSignIn(URL(string: "https://docs.google.com/document/d/1")!))
    }
}
