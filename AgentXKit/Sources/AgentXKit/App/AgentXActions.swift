import AppKit
import Foundation

/// What Siri, Shortcuts, Spotlight and Control Center can ask AgentX to do.
/// The App Intents live in the app target (App/Intents) and call these.
@MainActor
public enum AgentXActions {
    public struct AutomationSummary: Sendable, Hashable {
        public let id: UUID
        public let name: String
        /// "Weekdays at 8:00 · On this Mac"
        public let detail: String
    }

    public struct Project: Sendable, Hashable {
        public let path: String
        public let name: String
    }

    public enum Failure: LocalizedError {
        case noSuchAutomation, noSuchProject, cantStart(String)
        public var errorDescription: String? {
            switch self {
            case .noSuchAutomation: "That automation doesn't exist any more."
            case .noSuchProject: "That folder doesn't exist any more."
            case .cantStart(let why): why
            }
        }
    }

    /// Called when automations are added, renamed or removed (the app target
    /// refreshes Siri's list of automation names).
    public static var automationsChanged: (() -> Void)?

    private static var model: AppModel { AppModel.shared }

    // MARK: Lists

    public static func automations() -> [AutomationSummary] {
        model.automations.automations.map { a in
            let kind = switch a.kind {
            case .assistant: "Claude on this Mac"
            case .coding: "Coding in \((a.folder.map { ($0 as NSString).lastPathComponent }) ?? "a project")"
            case .onDevice: "Written on this Mac"
            case .notify: "Notification"
            }
            return AutomationSummary(id: a.id, name: a.name, detail: "\(a.enabled ? a.whenLabel : "Off") · \(kind)")
        }
    }

    /// Folders you've coded in, then your other clones, newest first.
    public static func projects() -> [Project] {
        var seen = Set<String>()
        let paths = model.sessions.recentProjects + model.github.clones.values.map(\.path).sorted()
        return paths.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
            .map { Project(path: $0, name: ($0 as NSString).lastPathComponent) }
    }

    // MARK: Doing

    /// Open the launcher, with `text` typed in (not sent).
    public static func openLauncher(text: String?) {
        LauncherController.shared.showFromLink(prefill: text?.isEmpty == false ? text : nil)
    }

    /// Do `request` as if you'd typed it in the launcher and pressed Return:
    /// on this Mac when it can be (apps, files, settings, calendar…), Claude when it needs to be.
    public static func run(_ request: String) {
        LauncherController.shared.run(request)
    }

    /// Ask Claude (with the Mac tools) and wait up to `wait` for the answer. Longer
    /// answers carry on in the launcher. The text came from a Shortcut, so it counts as
    /// untrusted: sending data out or saving a memory asks first.
    public static func askClaude(_ question: String, wait: Duration = .seconds(40)) async -> String {
        await model.bootstrap()
        guard model.client.status == .ready else { return "AgentX's engine isn't running. Open AgentX to see why." }
        if let blocked = model.sessions.startBlockedReason { return blocked }
        LocalUsage.noteClaude()
        let c = await model.askAssistant(question, taint: "a request passed in from Shortcuts or Siri")
        let deadline = ContinuousClock.now + wait
        try? await Task.sleep(for: .milliseconds(400))
        while c.isWorking, c.liveState != .waiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !c.isWorking {
            return LauncherController.lastAnswer(in: c) ?? c.error ?? "Claude didn't answer."
        }
        LauncherController.shared.showConversation(c.id)
        return c.liveState == .waiting
            ? "Claude needs your OK first. It's waiting in the AgentX launcher."
            : "Claude is still working on it. The answer will be in the AgentX launcher, and in Claude → On this Mac."
    }

    /// Run an automation now (like its Run Now button). Returns its name.
    @discardableResult
    public static func runAutomation(id: UUID, from source: String) async throws -> String {
        guard let automation = model.automations.automations.first(where: { $0.id == id }) else { throw Failure.noSuchAutomation }
        if automation.kind == .assistant || automation.kind == .coding {
            await model.bootstrap()
            guard model.client.status == .ready else { throw Failure.cantStart("AgentX's engine isn't running. Open AgentX to see why.") }
        }
        model.activity.record(.link, "ran", detail: "Started \(automation.name) from \(source).", origin: automation.name)
        model.automations.runNow(automation)
        return automation.name
    }

    /// Start a Claude Code session in `path` working on `task`, and show it.
    public static func startCodingSession(in path: String, task: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.noSuchProject }
        await model.bootstrap()
        if let blocked = model.sessions.startBlockedReason { throw Failure.cantStart(blocked) }
        model.sidebar = .sessions
        model.showMainWindow()
        let c = await model.sessions.startNew(cwd: path, prompt: task, model: nil, mode: .default)
        model.sessions.select(c.id)
    }

    /// Show a section of the main window.
    public static func open(_ section: SidebarItem) {
        model.sidebar = section
        model.showMainWindow()
    }

    /// The kill switch.
    public static func stopEverything(from source: String) async {
        await model.stopEverything(source: source)
    }
}
