// Development entry point: `swift run AgentXDev`, or scripts/run-dev.sh to
// get a proper .app bundle (needed for notifications and macOS permissions).
// The Xcode app target (../../../App/AgentXApp.swift) is identical.
import AgentXKit
import SwiftUI

@main
struct AgentXDevApp: App {
    @NSApplicationDelegateAdaptor(AgentXAppDelegate.self) var delegate
    var body: some Scene { AgentXScenes() }
}
