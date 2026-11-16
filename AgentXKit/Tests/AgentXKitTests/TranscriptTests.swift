import Foundation
import Testing
@testable import AgentXKit

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func decodesMixedValues() throws {
        let v = try json(#"{"a": 1, "b": true, "c": "x", "d": [1, null], "e": {"f": 2.5}}"#)
        #expect(v["a"]?.int == 1)
        #expect(v["b"]?.bool == true)
        #expect(v["c"]?.string == "x")
        #expect(v["d"]?[1]?.isNull == true)
        #expect(v["e"]?["f"]?.number == 2.5)
    }

    @Test func flattensToolResultContent() throws {
        let blocks = try json(#"[{"type":"text","text":"one"},{"type":"image"},{"type":"text","text":"two"}]"#)
        #expect(blocks.flattenedText == "one\n[image]\ntwo")
        #expect(JSONValue.string("plain").flattenedText == "plain")
    }

    @Test func decodesTypedModels() throws {
        let v = try json(#"{"sessionId":"abc","summary":"Fix bug","lastModified":1763316000000,"cwd":"/Users/me/Projects/app","gitBranch":"main"}"#)
        let s = try v.decode(SessionSummary.self)
        #expect(s.title == "Fix bug")
        #expect(s.projectName == "app")
        #expect(s.liveHandle == nil)
    }
}

@Suite("TranscriptBuilder")
struct TranscriptBuilderTests {
    @Test func buildsHistoryWithToolResults() throws {
        var b = TranscriptBuilder()
        b.add(try json(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"Fix the tests"}}"#))
        b.add(try json(#"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Running them."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}"#))
        b.add(try json(#"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"2 passing","is_error":false}]}}"#))

        let kinds = b.items.map(\.kind)
        #expect(kinds.count == 4)
        #expect(kinds[0] == .user("Fix the tests"))
        #expect(kinds[1] == .thinking("hmm"))
        #expect(kinds[2] == .assistant("Running them."))
        guard case .tool(let call) = kinds[3] else { Issue.record("expected tool"); return }
        #expect(call.name == "Bash")
        #expect(call.result == "2 passing")
        #expect(call.isError == false)
    }

    @Test func liveUserEchoesAreSkipped() throws {
        var b = TranscriptBuilder()
        b.addLocalUserText("hello")
        b.add(try json(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"hello"}}"#), live: true)
        #expect(b.items.count == 1)
    }

    @Test func subagentMessagesAreSkipped() throws {
        var b = TranscriptBuilder()
        b.add(try json(#"{"type":"assistant","uuid":"a1","parent_tool_use_id":"t9","message":{"role":"assistant","content":[{"type":"text","text":"sub"}]}}"#))
        #expect(b.items.isEmpty)
    }

    @Test func condensesSlashCommandsAndHidesReminders() throws {
        var b = TranscriptBuilder()
        b.add(try json(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"<command-name>/clear</command-name><command-args></command-args>"}}"#))
        b.add(try json(#"{"type":"user","uuid":"u2","message":{"role":"user","content":"<system-reminder>internal</system-reminder>"}}"#))
        #expect(b.items.map(\.kind) == [.notice("Ran /clear", isError: false)])
    }

    @Test func resultMessagesBecomeSummaries() throws {
        var b = TranscriptBuilder()
        b.add(try json(#"{"type":"result","uuid":"r1","subtype":"success","is_error":false,"duration_ms":12500,"total_cost_usd":0.02,"num_turns":3}"#))
        guard case .result(let r) = b.items.first?.kind else { Issue.record("expected result"); return }
        #expect(r.turns == 3)
        #expect(r.durationMs == 12500)
    }
}

@Suite("ToolPresentation")
struct ToolPresentationTests {
    @Test func summarizesCommonTools() {
        #expect(ToolPresentation.summary(name: "Bash", input: ["command": "ls", "description": "List files"], cwd: nil) == "List files")
        #expect(ToolPresentation.summary(name: "Edit", input: ["file_path": "/p/app/src/a.swift"], cwd: "/p/app") == "src/a.swift")
        #expect(ToolPresentation.displayName("mcp__agentx__calendar_list") == "agentx · calendar_list")
    }
}
