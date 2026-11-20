// Xcode app target entry point. All of the app lives in the AgentXKit package,
// except the App Intents (App/Intents), which macOS reads from the app itself.
import AgentXKit
import AppIntents
import SwiftUI

@main
struct AgentXApp: App {
    @NSApplicationDelegateAdaptor(AgentXAppDelegate.self) var delegate

    init() {
        // Siri learns your automations' names ("Run Morning brief in AgentX").
        AgentXActions.automationsChanged = { AgentXShortcuts.updateAppShortcutParameters() }
        AgentXShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene { AgentXScenes() }
}
