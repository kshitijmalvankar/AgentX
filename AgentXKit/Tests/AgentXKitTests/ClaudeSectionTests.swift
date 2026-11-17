import Foundation
import Testing
@testable import AgentXKit

@Suite("Chats section")
@MainActor
struct ClaudeSectionTests {
    @Test func oneSectionReplacesChatsAndAssistant() {
        #expect(SidebarItem.allCases.map(\.rawValue) == ["dashboard", "chats", "sessions", "github", "system", "automations"])
        #expect(ClaudeMode.mac.title == "On this Mac")
        #expect(ClaudeMode.web.explanation.contains("Can't act on your Mac"))
    }

    @Test func claudeAITextIsQuotedAndCapped() {
        let text = ClaudeWebController.handoffText("Line one\nLine two", title: "Trip ideas", isSelection: true)
        #expect(text.hasPrefix("Here's part of a chat I had on claude.ai (\"Trip ideas\"):\n\n> Line one\n> Line two"))
        let long = ClaudeWebController.handoffText(String(repeating: "x", count: 20_000), title: "", isSelection: false, limit: 100)
        #expect(long.hasPrefix("Here's a chat I had on claude.ai:\n\n> …"))
        #expect(long.count < 200)
    }

    @Test func macConversationBecomesPasteableMarkdown() {
        let c = Conversation(id: "c1", kind: .assistant, sessionId: nil, cwd: "/tmp", title: "Dark mode")
        c.addLocalPrompt("Turn on dark mode")
        c.apply(["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": "t1", "name": "mcp__agentx__system_appearance", "input": ["mode": "dark"]],
            ["type": "text", "text": "Done, dark mode is on."],
        ]]])
        let md = AppModel.handoffMarkdown(for: c)
        #expect(md.hasPrefix("Continuing a conversation I had with Claude on my Mac (Dark mode):"))
        #expect(md.contains("**Me:** Turn on dark mode"))
        #expect(md.contains("**Claude (on my Mac):** Done, dark mode is on."))
        #expect(!md.contains("system_appearance"), "tool calls stay out of the hand-off")
    }

    @Test func approvalBadgesCountByKind() async throws {
        let store = SessionStore(client: AgentClient())
        let mac = Conversation(id: "m", kind: .assistant, sessionId: "s-m", cwd: "/tmp", title: "Mac")
        mac.liveHandle = "hm"
        let code = Conversation(id: "c", kind: .coding, sessionId: "s-c", cwd: "/tmp", title: "Code")
        code.liveHandle = "hc"
        store.insert(mac)
        store.insert(code)
        Task {
            _ = try? await store.handleRequest("permission.request", params: ["handle": "hm", "toolName": "Bash", "input": [:]], id: "1")
        }
        Task {
            _ = try? await store.handleRequest("permission.request", params: ["handle": "hc", "toolName": "Bash", "input": [:]], id: "2")
        }
        Task {
            _ = try? await store.handleRequest("permission.request", params: ["handle": "hc", "toolName": "Edit", "input": [:]], id: "3")
        }
        // Let the three requests register.
        for _ in 0..<200 where store.approvals.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.approvalCount(kind: .assistant) == 1)
        #expect(store.approvalCount(kind: .coding) == 2)
        for a in store.approvals { store.answer(a, .deny()) }
    }
}
