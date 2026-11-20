import AppIntents

/// Ready-made shortcuts: Siri phrases, and actions in Spotlight and the Shortcuts app.
struct AgentXShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskAgentXIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) to do something"],
                    shortTitle: "Ask", systemImageName: "sparkle.magnifyingglass")
        AppShortcut(intent: RunAutomationIntent(),
                    phrases: ["Run \(\.$automation) in \(.applicationName)", "Run an automation in \(.applicationName)"],
                    shortTitle: "Run Automation", systemImageName: "clock.arrow.2.circlepath")
        AppShortcut(intent: AskClaudeIntent(),
                    phrases: ["Ask Claude in \(.applicationName)"],
                    shortTitle: "Ask Claude", systemImageName: "text.bubble")
        AppShortcut(intent: OpenSectionIntent(),
                    phrases: ["Open \(.applicationName)", "Show \(\.$section) in \(.applicationName)"],
                    shortTitle: "Open", systemImageName: "macwindow")
        AppShortcut(intent: StopEverythingIntent(),
                    phrases: ["Stop everything in \(.applicationName)"],
                    shortTitle: "Stop Everything", systemImageName: "stop.circle")
    }

    static let shortcutTileColor: ShortcutTileColor = .purple
}
