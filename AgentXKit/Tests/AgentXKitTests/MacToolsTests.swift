import Foundation
import Testing
@testable import AgentXKit

@Suite("Mac toolbox")
struct MacToolboxTests {
    @Test func toolsAreWellFormed() {
        let names = MacToolbox.tools.map(\.name)
        #expect(Set(names).count == names.count, "tool names must be unique")
        for tool in MacToolbox.tools {
            #expect(tool.name.range(of: "^[a-z][a-z_]+$", options: .regularExpression) != nil, "\(tool.name)")
            #expect(!tool.description.isEmpty && !tool.summary.isEmpty)
            #expect(tool.qualifiedName == "mcp__agentx__\(tool.name)")
        }
    }

    @Test func riskyActionsAskFirst() {
        let ask = Set(MacToolbox.tools.filter { $0.risk == .ask }.map(\.name))
        #expect(ask == ["reminders_complete", "files_move", "files_trash", "apps_quit", "shortcuts_run",
                        "clipboard_read", "mail_send", "messages_send", "memory_forget"])
        #expect(MacToolbox.tool(named: "mail_draft")?.risk == .create)
        #expect(MacToolbox.tool(named: "calendar_events")?.risk == .read)
    }

    @Test func definitionsCarryTypesForAgentCore() throws {
        let send = try #require(MacToolbox.definitions.array?.first { $0["name"]?.string == "mail_send" })
        #expect(send["risk"]?.string == "ask")
        let to = try #require(send["parameters"]?.array?.first { $0["name"]?.string == "to" })
        #expect(to["type"]?.string == "string[]")
        #expect(to["required"]?.bool == true)
        let appearance = try #require(MacToolbox.definitions.array?.first { $0["name"]?.string == "system_appearance" })
        #expect(appearance["parameters"]?[0]?["enum"]?.array?.compactMap(\.string) == ["dark", "light"])
    }

    @Test func unknownToolsAndBadArgumentsComeBackAsErrors() async {
        let unknown = await MacToolbox.invoke(name: "nope", arguments: [:])
        #expect(unknown["isError"]?.bool == true)
        let backwards = await MacToolbox.invoke(name: "calendar_create_event",
                                                arguments: ["title": "x", "start": "2026-11-17T15:00", "end": "2026-11-17T14:00"])
        #expect(backwards["isError"]?.bool == true)
        #expect(backwards["text"]?.string?.contains("end must be after") == true)
    }

    @Test func parsesDatesClaudeSends() {
        let local = ToolDates.parse("2026-11-17T15:30")
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: local!)
        #expect(c.year == 2026 && c.month == 11 && c.day == 17 && c.hour == 15 && c.minute == 30)
        #expect(ToolDates.parse("2026-11-17") != nil)
        #expect(ToolDates.parse("2026-11-17T15:30:00Z") != nil)
        #expect(ToolDates.parse("2026-11-17T15:30:00+05:30") != nil)
        #expect(ToolDates.parse("next tuesday") == nil)
    }
}

@Suite("Running programs and AppleScript")
struct ProcessAndAppleScriptTests {
    @Test func appleScriptTakesValuesAsArgumentsNotCode() async throws {
        let hostile = #"x" & (do shell script "echo pwned") & ""#
        let echoed = try await AppleScript.run("""
            on run argv
              return item 1 of argv
            end run
            """, arguments: [hostile])
        #expect(echoed == hostile)
    }

    @Test func explainsMissingAutomationPermission() {
        let text = AppleScript.explain(#"execution error: Not authorized to send Apple events to Mail. (-1743)"#)
        #expect(text.contains("System Settings › Privacy & Security › Automation"))
    }

    @Test func slowProgramsAreStopped() async {
        await #expect(throws: ToolError.self) {
            _ = try await ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.5)
        }
    }

    @Test func listsOpenAppsAndMovesFilesSafely() async throws {
        let apps = await MacToolbox.invoke(name: "apps_running", arguments: [:])
        #expect(apps["isError"]?.bool == false)
        #expect(apps["text"]?.string?.contains("Finder") == true)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentx-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        let moved = await MacToolbox.invoke(name: "files_move", arguments: ["from": .string(file.path), "to": .string(dir.appendingPathComponent("inbox").path)])
        #expect(moved["isError"]?.bool == false)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("inbox/note.txt").path))

        try "again".write(to: file, atomically: true, encoding: .utf8)
        let clash = await MacToolbox.invoke(name: "files_move", arguments: ["from": .string(file.path), "to": .string(dir.appendingPathComponent("inbox").path)])
        #expect(clash["isError"]?.bool == true, "never overwrites")
    }
}

@Suite("Tool activity lines")
struct ToolActivityTests {
    @Test func everyMacToolHasAPlainLanguageLine() {
        for tool in MacToolbox.tools {
            #expect(ToolPresentation.agentxActivity[tool.name] != nil, "missing activity for \(tool.name)")
        }
    }

    @Test func readsLikeASentence() {
        let dark = ToolPresentation.activity(name: "mcp__agentx__system_appearance", input: ["mode": "dark"], cwd: nil)
        #expect(dark.title == "Changed appearance" && dark.detail == "Dark")
        let week = ToolPresentation.activity(name: "mcp__agentx__calendar_events",
                                              input: ["start": "2026-11-23T00:00", "end": "2026-11-29T23:59"], cwd: nil)
        #expect(week.title == "Checked your calendar")
        #expect(week.detail.contains("23") && week.detail.contains("29") && week.detail.contains("–"))
        let bash = ToolPresentation.activity(name: "Bash", input: ["command": "ps aux", "description": "Inspect processes"], cwd: nil)
        #expect(bash.title == "Ran a command" && bash.detail == "Inspect processes")
        let edit = ToolPresentation.activity(name: "Edit", input: ["file_path": "/p/app/src/a.swift"], cwd: "/p/app")
        #expect(edit.title == "Edited" && edit.detail == "src/a.swift")
    }

    @Test func transcriptSpacingGroupsToolCalls() {
        let call = TranscriptKind.tool(ToolCall(id: "1", name: "Bash", input: [:]))
        #expect(TranscriptView.gap(after: call, before: call) < TranscriptView.gap(after: .assistant("x"), before: .assistant("y")))
        #expect(TranscriptView.gap(after: .user("q"), before: .assistant("a")) > TranscriptView.gap(after: .assistant("a"), before: call))
    }
}
