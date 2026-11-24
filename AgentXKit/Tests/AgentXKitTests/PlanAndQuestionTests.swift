import Foundation
import Testing
@testable import AgentXKit

@Suite("Plans and questions")
@MainActor
struct PlanAndQuestionTests {
    private let input: JSONValue = [
        "questions": [
            ["question": "Which focus?", "header": "Focus", "multiSelect": true,
             "options": [["label": "Simple mode", "description": "Hide developer parts"],
                         ["label": "Recipes", "description": "One-tap automations"]]],
            ["question": "Which colour?", "header": "Colour", "multiSelect": false,
             "options": [["label": "Blue", "description": ""], ["label": "Green", "description": ""]]],
        ],
    ]

    @Test func questionsAreReadFromTheToolInput() {
        let questions = ClaudeQuestion.all(in: input)
        #expect(questions.map(\.header) == ["Focus", "Colour"])
        #expect(questions[0].multiSelect && !questions[1].multiSelect)
        #expect(questions[0].options.map(\.label) == ["Simple mode", "Recipes"])
    }

    @Test func answersGoBackAsClaudeCodeExpects() {
        let answered = ClaudeQuestion.answered(input, picks: ["Which focus?": ["Simple mode", "Recipes"], "Which colour?": ["Blue"]],
                                               other: ["Which colour?": "  teal  "])
        #expect(answered["answers"]?["Which focus?"]?.string == "Simple mode, Recipes", "several picks, comma-separated")
        #expect(answered["answers"]?["Which colour?"]?.string == "Blue, teal", "your own words come after the picks")
        #expect(answered["questions"]?.array?.count == 2, "the questions stay as they were")
    }

    @Test func approvalAnswersLeaveOutWhatIsntSet() {
        #expect(ApprovalAnswer.allowWith(input: nil, mode: .acceptEdits).json == ["behavior": "allow", "mode": "acceptEdits"])
        let withInput = ApprovalAnswer.allowWith(input: ["answers": [:]], mode: nil).json
        #expect(withInput["mode"] == nil && withInput["updatedInput"] != nil)
        #expect(ApprovalAnswer.allow.json == ["behavior": "allow"])
    }

    @Test func theNewestPlanIsFound() {
        let c = Conversation(id: "c1", sessionId: nil, cwd: "/tmp", title: "t")
        #expect(c.latestPlan == nil)
        // Claude Code messages, as a session's history has them.
        func toolUse(_ id: String, _ input: JSONValue) -> JSONValue {
            ["type": "assistant", "uuid": .string("m-" + id),
             "message": ["role": "assistant", "content": [["type": "tool_use", "id": .string(id), "name": "ExitPlanMode", "input": input]]]]
        }
        c.apply(toolUse("a", ["plan": "# Old", "planFilePath": "/p.md"]))
        c.apply(["type": "assistant", "uuid": "m-x", "message": ["role": "assistant", "content": [["type": "text", "text": "ok"]]]])
        c.apply(toolUse("b", ["plan": "# New"]))
        c.apply(toolUse("c", [:]))
        #expect(c.latestPlan?.text == "# New", "an empty call (the transcript's echo) is skipped")
        #expect(c.latestPlan?.path == nil)
    }
}
