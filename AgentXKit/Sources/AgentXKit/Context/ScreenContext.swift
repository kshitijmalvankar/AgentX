import AppKit
import ApplicationServices
import Foundation

/// What was in front of you when you opened the launcher: the app, its
/// window, your selection, the browser tab, Finder's selection. Captured only
/// when you open the launcher (or Claude calls context_now in a conversation
/// you're in), shown as chips you can remove, and sent framed as untrusted
/// text: a web page title or a selection can contain anything.
public struct ScreenContext: Equatable, Sendable {
    public struct BrowserTab: Equatable, Sendable {
        public var title: String
        public var url: String
    }

    public var appName: String
    public var bundleID: String?
    public var windowTitle: String?
    public var documentPath: String?
    public var selectedText: String?
    /// The selection looked like a secret, so it wasn't kept (what kind).
    public var selectionWithheld: String?
    public var browserTab: BrowserTab?
    public var finderSelection: [String] = []
    /// AgentX can't read windows or selections until you allow Accessibility.
    public var needsAccessibility = false
    /// AgentX isn't allowed to read this browser's tab or Finder (the app's name).
    public var automationBlocked: String?

    /// The bits worth sending (the app name alone isn't).
    public var hasDetails: Bool {
        windowTitle != nil || documentPath != nil || selectedText != nil || browserTab != nil || !finderSelection.isEmpty
    }

    /// The text that goes in front of your message.
    public func promptBlock(limit: Int = 8_000) -> String {
        var lines = ["App: \(appName)"]
        if let tab = browserTab {
            lines.append("Browser tab: \(Self.clean(tab.title, 300)) (\(Self.clean(tab.url, 600)))")
        } else if let title = windowTitle {
            lines.append("Window: \(Self.clean(title, 300))")
        }
        if let path = documentPath { lines.append("Document: \(Self.clean(path, 600))") }
        if !finderSelection.isEmpty {
            lines.append("Selected in Finder:")
            lines += finderSelection.prefix(20).map { "- \(Self.clean($0, 600))" }
            if finderSelection.count > 20 { lines.append("- … and \(finderSelection.count - 20) more") }
        }
        if let text = selectedText {
            lines.append("Selected text:")
            lines.append(Self.clean(text, limit))
        }
        return """
        (What was on my screen when I asked; use it if it's relevant.)
        <untrusted source="what's on the user's screen">
        \(lines.joined(separator: "\n"))
        </untrusted>
        """
    }

    /// Why the conversation should count as having read untrusted content, or nil.
    public var taintReason: String? {
        hasDetails ? "what was on your screen (\(appName))" : nil
    }

    /// Shorten, and neutralize anything that could close the untrusted block early.
    static func clean(_ text: String, _ limit: Int) -> String {
        var t = text.replacingOccurrences(of: #"</?\s*untrusted[^>]*>"#, with: "[tag removed]", options: [.regularExpression, .caseInsensitive])
        if t.count > limit { t = String(t.prefix(limit)) + "…" }
        return t
    }

    /// A user message as it should be shown: the screen block becomes a short note.
    public static func displayText(_ prompt: String) -> String {
        guard let start = prompt.range(of: "(What was on my screen when I asked; use it if it's relevant.)\n<untrusted source=\"what's on the user's screen\">"),
              let end = prompt.range(of: "</untrusted>", range: start.upperBound..<prompt.endIndex) else { return prompt }
        var rest = prompt
        rest.removeSubrange(start.lowerBound..<end.upperBound)
        let typed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? "(shared what was on screen)" : typed + "\n\n(with what was on screen)"
    }
}

/// Remembers the last app you used that isn't AgentX, so "what's on my
/// screen" means that app even while AgentX is in front.
@MainActor
final class FrontmostTracker {
    static let shared = FrontmostTracker()
    private(set) var lastApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        note(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.note(app) }
        }
    }

    private func note(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastApp = app
    }
}

/// Reading other apps through macOS Accessibility (needs your OK once in
/// System Settings › Privacy & Security › Accessibility). Read-only here;
/// never reads password fields.
enum AXReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show macOS's "allow AgentX to control your computer" prompt.
    static func requestTrust() {
        // The value of kAXTrustedCheckOptionPrompt (a C global Swift 6 won't read directly).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Apps built on Chromium or Electron only build their accessibility tree when asked to.
    private static let chromiumLike: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.hnc.Discord", "notion.id",
    ]

    /// The focused window's title and document, and the selected text (nil if it's a password field).
    static func read(pid: pid_t, bundleID: String?) -> (title: String?, document: String?, selection: String?) {
        guard isTrusted else { return (nil, nil, nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        if let bundleID, chromiumLike.contains(bundleID) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var title: String?, document: String?
        if let window: AXUIElement = copy(app, kAXFocusedWindowAttribute) {
            title = copy(window, kAXTitleAttribute)
            if let doc: String = copy(window, kAXDocumentAttribute) {
                document = URL(string: doc).map { $0.isFileURL ? $0.path : doc } ?? doc
            }
        }
        var selection: String?
        if let focused: AXUIElement = copy(app, kAXFocusedUIElementAttribute) {
            let role: String? = copy(focused, kAXRoleAttribute)
            let subrole: String? = copy(focused, kAXSubroleAttribute)
            let secure = subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
            if !secure, let text: String = copy(focused, kAXSelectedTextAttribute) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { selection = trimmed }
            }
        }
        return (title?.isEmpty == true ? nil : title, document, selection)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement) as? T
        }
        return value as? T
    }
}

/// Gathering a ScreenContext for an app.
enum ContextCapture {
    /// Browsers AgentX can ask for the current tab (AppleScript), by bundle id.
    static let browsers: [String: AutomationTarget] = [
        "com.apple.Safari": .safari, "com.google.Chrome": .chrome, "com.microsoft.edgemac": .edge,
        "com.brave.Browser": .brave, "company.thebrowser.Browser": .arc, "com.vivaldi.Vivaldi": .vivaldi,
    ]

    static func capture(_ app: NSRunningApplication) async -> ScreenContext {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        var context = ScreenContext(appName: app.localizedName ?? "the app", bundleID: bundleID)
        let ax = await Task.detached(priority: .userInitiated) { AXReader.read(pid: pid, bundleID: bundleID) }.value
        context.needsAccessibility = !AXReader.isTrusted
        context.windowTitle = ax.title
        context.documentPath = ax.document
        if let selection = ax.selection {
            if let secret = SecretDetector.find(in: selection) { context.selectionWithheld = secret } else { context.selectedText = selection }
        }

        if let bundleID, let browser = browsers[bundleID] {
            do { context.browserTab = try await browserTab(browser) } catch { context.automationBlocked = browser.name }
        } else if bundleID == "com.apple.finder" {
            do { context.finderSelection = try await finderSelection() } catch { context.automationBlocked = "Finder" }
        }
        return context
    }

    static func browserTab(_ browser: AutomationTarget) async throws -> ScreenContext.BrowserTab? {
        let tabTerm = browser == .safari ? "current tab" : "active tab"
        let titleTerm = browser == .safari ? "name" : "title"
        let output = try await AppleScript.run("""
            tell application "\(browser.name)"
              if (count of windows) is 0 then return ""
              set t to \(tabTerm) of front window
              return (URL of t) & linefeed & (\(titleTerm) of t)
            end tell
            """, timeout: 4)
        let parts = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let url = parts.first, !url.isEmpty else { return nil }
        return .init(title: parts.count > 1 ? parts[1] : "", url: url)
    }

    static func finderSelection() async throws -> [String] {
        let output = try await AppleScript.run("""
            tell application "Finder"
              set out to ""
              repeat with f in (selection as alias list)
                set out to out & (POSIX path of f) & linefeed
              end repeat
              return out
            end tell
            """, timeout: 4)
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
