import Foundation
import Testing
@testable import AgentXKit

@Suite("Launcher and voice")
struct LauncherTests {
    @Test func answersAreReadWithoutMarkdown() {
        let spoken = SpeechOutput.plainText("""
        ## Nvidia
        - **Founded** in 1993 by [Jensen Huang](https://example.com).
        - Ticker: `NVDA`

        ```swift
        print("hi")
        ```
        """)
        #expect(spoken == "Nvidia\nFounded in 1993 by Jensen Huang.\nTicker: NVDA\n(code on screen)")
    }

    @Test @MainActor func quickActionsAskForJustTheTextWhenItWillReplaceIt() {
        let fix = LauncherController.selectionActions.first { $0.title == "Fix the Writing" }
        #expect(fix?.prompt.contains("Reply with only") == true)
    }

    @Test func readingAloudIsOffUnlessTurnedOn() async {
        let on = await MainActor.run { UserDefaults.standard.object(forKey: "voiceReadAloud") == nil ? SpeechOutput.readAloud : false }
        #expect(on == false)
    }

    @Test @MainActor func onlyMessagesAboutTheScreenTakeIt() {
        let launcher = LauncherController.shared
        #expect(!launcher.wantsScreen(for: "What's my latest email from Enda") || LauncherController.ContextMode.current == .ask)
        #expect(launcher.wantsScreen(for: "summarize this"))
    }
}
