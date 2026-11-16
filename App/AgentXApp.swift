// Xcode app target entry point. All of the app lives in the AgentXKit package.
import AgentXKit
import SwiftUI

@main
struct AgentXApp: App {
    @NSApplicationDelegateAdaptor(AgentXAppDelegate.self) var delegate
    var body: some Scene { AgentXScenes() }
}
