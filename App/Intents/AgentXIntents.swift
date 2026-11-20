import AgentXKit
import AppIntents
import Foundation

// What Siri, Shortcuts and Spotlight can do with AgentX. Each one calls
// AgentXActions (in AgentXKit), which does the work inside the running app.

/// Like typing in the launcher and pressing Return.
struct AskAgentXIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask AgentX"
    static let description = IntentDescription(
        "Opens the AgentX launcher with your request and does it: on this Mac when it can (apps, files, settings, your calendar and reminders), with Claude when it needs to. The result shows in the launcher.",
        categoryName: "Ask")

    @Parameter(title: "Request", requestValueDialog: "What should AgentX do?")
    var request: String

    static var parameterSummary: some ParameterSummary { Summary("Ask AgentX to \(\.$request)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AgentXActions.run(request)
        return .result()
    }
}

/// Open the launcher, optionally with text typed in.
struct OpenLauncherIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the AgentX Launcher"
    static let description = IntentDescription("Opens the launcher over the app you're in, like the keyboard shortcut.",
                                               categoryName: "Ask")

    @Parameter(title: "Text", description: "Typed into the launcher, not sent.")
    var text: String?

    static var parameterSummary: some ParameterSummary { Summary("Open the launcher with \(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AgentXActions.openLauncher(text: text)
        return .result()
    }
}

/// Claude's answer as text, for Shortcuts that do something with it.
struct AskClaudeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get an Answer from Claude"
    static let description = IntentDescription(
        "Asks Claude on this Mac (with AgentX's Mac tools) and returns the answer. Uses your Claude plan. If it takes longer than about 40 seconds, the answer carries on in the AgentX launcher. Sending anything out or saving a memory always asks you first.",
        categoryName: "Ask")

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Claude?")
    var question: String

    static var parameterSummary: some ParameterSummary { Summary("Ask Claude \(\.$question)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await AgentXActions.askClaude(question)
        let spoken = answer.count > 600 ? String(answer.prefix(600)) + "…" : answer
        return .result(value: answer, dialog: "\(spoken)")
    }
}

struct RunAutomationIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Automation"
    static let description = IntentDescription("Runs one of your AgentX automations now, like its Run Now button.",
                                               categoryName: "Automations")

    @Parameter(title: "Automation")
    var automation: AutomationEntity

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$automation)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await AgentXActions.runAutomation(id: automation.id, from: "Shortcuts or Siri")
        return .result(dialog: "Started \(name). You'll get a notification when it's done.")
    }
}

struct StartCodingSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Coding Session"
    static let description = IntentDescription("Starts a Claude Code session in a project folder and shows it in AgentX.",
                                               categoryName: "Coding")
    static let openAppWhenRun = true

    @Parameter(title: "Project")
    var project: ProjectEntity

    @Parameter(title: "Task", requestValueDialog: "What should Claude work on?")
    var task: String

    static var parameterSummary: some ParameterSummary { Summary("In \(\.$project), \(\.$task)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AgentXActions.startCodingSession(in: project.id, task: task)
        return .result()
    }
}

struct OpenSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open AgentX"
    static let description = IntentDescription("Opens AgentX's window on a section.", categoryName: "Open")
    static let openAppWhenRun = true

    @Parameter(title: "Section", default: .dashboard)
    var section: SectionOption

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$section) in AgentX") }

    @MainActor
    func perform() async throws -> some IntentResult {
        AgentXActions.open(section.item)
        return .result()
    }
}

/// The kill switch.
struct StopEverythingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Everything in AgentX"
    static let description = IntentDescription(
        "Stops every running Claude session, turns down waiting approvals and pauses automations.",
        categoryName: "Safety")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AgentXActions.stopEverything(from: "Shortcuts or Siri")
        return .result(dialog: "Stopped. Automations stay paused until you turn them back on.")
    }
}
