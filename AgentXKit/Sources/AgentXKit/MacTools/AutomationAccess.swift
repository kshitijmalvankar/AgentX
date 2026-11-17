import AppKit
import CoreServices
import Foundation

/// Apps the assistant controls with AppleScript, which macOS guards under
/// Privacy & Security › Automation.
public enum AutomationTarget: String, CaseIterable, Identifiable, Sendable {
    case mail = "com.apple.mail"
    case notes = "com.apple.Notes"
    case messages = "com.apple.MobileSMS"
    case systemEvents = "com.apple.systemevents"
    case finder = "com.apple.finder"
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"
    case edge = "com.microsoft.edgemac"
    case brave = "com.brave.Browser"
    case arc = "company.thebrowser.Browser"
    case vivaldi = "com.vivaldi.Vivaldi"

    public var id: String { rawValue }

    /// The name AppleScript uses (`tell application "Mail"`).
    public var name: String {
        switch self {
        case .mail: "Mail"
        case .notes: "Notes"
        case .messages: "Messages"
        case .systemEvents: "System Events"
        case .finder: "Finder"
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave Browser"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        }
    }

    /// On this Mac (Settings only lists apps you have).
    public var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil
    }

    public var purpose: String {
        switch self {
        case .mail: "Read recent mail, draft and send email"
        case .notes: "Search and create notes"
        case .messages: "Send iMessages"
        case .systemEvents: "Dark mode and volume"
        case .finder: "What's selected in Finder, when you open the launcher"
        case .safari, .chrome, .edge, .brave, .arc, .vivaldi: "The current tab's address and title, when you open the launcher"
        }
    }

    /// The target an AppleScript talks to, from its `tell application "…"`.
    static func of(script: String) -> AutomationTarget? {
        guard let range = script.range(of: #"tell application "([^"]+)""#, options: .regularExpression) else { return nil }
        let app = script[range].dropFirst("tell application \"".count).dropLast()
        return allCases.first { $0.name == app }
    }
}

/// Asking macOS for Automation permission from AgentX itself.
///
/// The assistant's AppleScript runs in `osascript`, a helper AgentX starts.
/// Letting that helper be the first to ask can leave macOS refusing without
/// ever showing the "AgentX wants to control Mail" prompt. So AgentX checks
/// (and, when needed, asks) with `AEDeterminePermissionToAutomateTarget`
/// before a script runs, and Settings → Assistant shows where each app stands.
public enum AutomationAccess {
    public enum Status: Equatable, Sendable {
        case allowed
        /// macOS hasn't asked yet.
        case notAsked
        case denied
        /// The app isn't open, so macOS can't say yet.
        case unknown
    }

    /// Where things stand, without prompting or opening the app.
    public static func status(of target: AutomationTarget) async -> Status {
        await Task.detached(priority: .userInitiated) { check(target, ask: false) }.value
    }

    /// Show macOS's prompt if it hasn't been answered (opening the app in the
    /// background first, since macOS only asks about a running app).
    public static func request(_ target: AutomationTarget) async -> Status {
        await launchIfNeeded(target)
        return await Task.detached(priority: .userInitiated) { check(target, ask: true) }.value
    }

    /// Before a script runs: ask if needed, and fail with a way to fix it if access is off.
    static func ensure(_ target: AutomationTarget) async throws {
        switch await request(target) {
        case .allowed, .unknown:
            return
        case .notAsked, .denied:
            throw ToolError("AgentX isn't allowed to control \(target.name). Fix it in AgentX Settings → Assistant → Permissions (Reset and Ask Again), or turn it on in System Settings › Privacy & Security › Automation › \(AppChannel.current.displayName).")
        }
    }

    /// Forget AgentX's Automation answers (all apps), so macOS asks again.
    /// Only ever run when you click "Reset and Ask Again".
    public static func resetAll() async throws {
        guard let bundleID = Bundle.main.bundleIdentifier else { throw ToolError("AgentX has no bundle id to reset.") }
        let result = try await ProcessRunner.run("/usr/bin/tccutil", ["reset", "AppleEvents", bundleID], timeout: 15)
        guard result.status == 0 else { throw ToolError("Couldn't reset: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    private static func check(_ target: AutomationTarget, ask: Bool) -> Status {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: target.rawValue)
        guard let desc = descriptor.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch Int(status) {
        case Int(noErr): return .allowed
        case Int(errAEEventWouldRequireUserConsent): return .notAsked
        case Int(errAEEventNotPermitted): return .denied
        default: return .unknown   // e.g. procNotFound: the app isn't running
        }
    }

    private static func launchIfNeeded(_ target: AutomationTarget) async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: target.rawValue).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.rawValue) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<30 where NSRunningApplication.runningApplications(withBundleIdentifier: target.rawValue).isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
