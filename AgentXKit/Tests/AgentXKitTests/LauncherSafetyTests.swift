import Foundation
import Testing
@testable import AgentXKit

/// What "Ask AgentX" from Siri, Shortcuts or Spotlight may do without you seeing it first.
@Suite("Ask AgentX from outside")
struct LauncherSafetyTests {
    @Test func onlySafeRowsRunByThemselves() {
        #expect(LauncherController.runsByItself(.open(URL(fileURLWithPath: "/Applications/Safari.app"))))
        #expect(LauncherController.runsByItself(.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)))
        #expect(!LauncherController.runsByItself(.open(URL(string: "https://example.com/login")!)), "a web page waits for you")
        #expect(!LauncherController.runsByItself(.tool(name: "apps_quit", args: ["name": "Xcode"], done: "Quit Xcode")))
        #expect(!LauncherController.runsByItself(.code("/code agentx delete the tests")))
        #expect(LauncherController.runsByItself(.askClaude("what's on my calendar?")))
        #expect(LauncherController.runsByItself(.local(LocalPlan(action: .showCalendar))))
        #expect(!LauncherController.runsByItself(.local(LocalPlan(action: .quitApp))))
        #expect(LauncherController.runsByItself(.copy("42")))
    }
}
