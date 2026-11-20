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
        // Chrome reports the page address as the window's document: already in the tab line.
        if let path = documentPath, path != browserTab?.url { lines.append("Document: \(Self.clean(path, 600))") }
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

    /// Whether a spoken question is about what's on screen ("summarize this",
    /// "what does this page say"). Spoken questions are sent without a look at
    /// the chips, so the screen goes along only when the words point at it.
    public static func refersToScreen(_ text: String) -> Bool {
        let t = text.lowercased()
        let times = "week|weekend|month|year|morning|afternoon|evening|time|monday|tuesday|wednesday|thursday|friday|saturday|sunday"
        let pointers = #"\b(this|these|those|here)\b(?!\s+(\#(times))\b)"#
        // Nouns that mean the screen. Not "email" or "document": "my latest email" is about the inbox
        // ("this email" still counts, through "this").
        let things = #"\b(selected|selection|highlighted|screen|page|tab|window|article|paragraph|sentence|chart|looking at)\b"#
        return t.range(of: pointers, options: .regularExpression) != nil || t.range(of: things, options: .regularExpression) != nil
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

    static let blockStart = "(What was on my screen when I asked; use it if it's relevant.)\n<untrusted source=\"what's on the user's screen\">"

    /// A prompt split into what you typed and a short note on what was shared
    /// from your screen (nil if it carries no screen block).
    public static func split(_ prompt: String) -> (typed: String, shared: String?) {
        guard let start = prompt.range(of: blockStart),
              let end = prompt.range(of: "</untrusted>", range: start.upperBound..<prompt.endIndex) else { return (prompt, nil) }
        let lines = prompt[start.upperBound..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rest = prompt
        rest.removeSubrange(start.lowerBound..<end.upperBound)
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), sharedNote(lines))
    }

    /// A user message as it should be shown: the screen block becomes a note
    /// saying what was shared ("Shared from Safari: selected text “…”, tab “…”").
    public static func displayText(_ prompt: String) -> String {
        let (typed, shared) = split(prompt)
        guard let shared else { return prompt }
        return typed.isEmpty ? "(\(shared))" : typed + "\n\n(\(shared))"
    }

    /// A shown message split into what you wrote and the notes AgentX added
    /// ("Shared from …", "with a picture of the window"), to draw them apart.
    public static func notes(in display: String) -> (text: String, notes: [String]) {
        var text = display.trimmingCharacters(in: .whitespacesAndNewlines)
        var notes: [String] = []
        while text.hasSuffix(")") {
            let start = text.range(of: "\n\n(", options: .backwards).map { text.index(after: text.index(after: $0.lowerBound)) }
                ?? (text.hasPrefix("(") ? text.startIndex : nil)
            guard let start else { break }
            let note = String(text[text.index(after: start)..<text.index(before: text.endIndex)])
            guard note.hasPrefix("Shared ") || note.hasPrefix("with a picture"), !note.contains("\n") else { break }
            notes.insert(note.prefix(1).uppercased() + note.dropFirst(), at: 0)
            text = String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (text, notes)
    }

    private static func sharedNote(_ lines: [String]) -> String {
        func value(_ prefix: String) -> String? {
            lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        func short(_ s: String, _ n: Int) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        var parts: [String] = []
        if let i = lines.firstIndex(of: "Selected text:") {
            parts.append("selected text “\(short(lines[(i + 1)...].joined(separator: " "), 60))”")
        }
        if let i = lines.firstIndex(of: "Selected in Finder:") {
            let files = lines[(i + 1)...].prefix { $0.hasPrefix("- ") }
            let more = files.last.flatMap { Int($0.replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression)) }
            let count = files.last?.hasPrefix("- … and ") == true ? files.count - 1 + (more ?? 0) : files.count
            parts.append(count == 1 ? "the file \((files.first!.dropFirst(2) as NSString).lastPathComponent)" : "\(count) files")
        }
        if let tab = value("Browser tab: ") {
            let title = tab.range(of: " (", options: .backwards).map { String(tab[..<$0.lowerBound]) } ?? tab
            parts.append("the tab “\(short(title, 50))”")
        } else if let window = value("Window: ") {
            parts.append("the window “\(short(window, 50))”")
        } else if let document = value("Document: ") {
            parts.append("the document \((document as NSString).lastPathComponent)")
        }
        let app = value("App: ") ?? "your screen"
        return parts.isEmpty ? "Shared what was on screen (\(app))" : "Shared from \(app): " + parts.joined(separator: ", ")
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
        guard let app else { return }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            agentXCameForwardAt = Date()
            return
        }
        lastApp = app
    }

    /// When AgentX last became the active app.
    private(set) var agentXCameForwardAt: Date?

    /// The app to give the screen back to, when AgentX came forward in the last
    /// `seconds` (an agentx:// link from Control Center or a Shortcut brings it forward).
    func appToReturnTo(within seconds: TimeInterval = 2) -> NSRunningApplication? {
        guard let at = agentXCameForwardAt, Date().timeIntervalSince(at) < seconds,
              let app = lastApp, !app.isTerminated else { return nil }
        return app
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

    /// Chromium browsers don't share a web page's selection through
    /// Accessibility (unless a screen reader is on), so the launcher copies it.
    static let hidesSelection: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// The focused window's title and document, and the selected text (nil if
    /// it's a password field). `selectionKnown`: the app answered whether
    /// anything is selected, so a nil selection really means nothing is.
    static func read(pid: pid_t, bundleID: String?) -> (title: String?, document: String?, selection: String?, selectionKnown: Bool) {
        guard isTrusted else { return (nil, nil, nil, false) }
        let app = element(pid: pid, bundleID: bundleID, timeout: 0.4)
        var title: String?, document: String?
        if let window: AXUIElement = copy(app, kAXFocusedWindowAttribute) {
            title = copy(window, kAXTitleAttribute)
            if let doc: String = copy(window, kAXDocumentAttribute), !doc.isEmpty {
                document = URL(string: doc).map { $0.isFileURL ? $0.path : doc } ?? doc
            }
        }
        var selection: String?
        var known = false
        if let focused: AXUIElement = copy(app, kAXFocusedUIElementAttribute), !isSecure(focused) {
            if let text: String = copy(focused, kAXSelectedTextAttribute) {
                known = true
                selection = text
            } else if let range: CFTypeRef = copy(focused, "AXSelectedTextMarkerRange") {
                // Web pages (Safari, WebKit views): the selection is a text-marker range.
                known = true
                var value: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(focused, "AXStringForTextMarkerRange" as CFString, range, &value) == .success {
                    selection = value as? String
                }
            }
        }
        let trimmed = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == true ? nil : title, document, trimmed?.isEmpty == false ? trimmed : nil, known)
    }

    /// How long the selection is, without reading it: 0 when nothing is
    /// selected, nil when the app doesn't say (Chrome and friends).
    static func selectionLength(pid: pid_t, bundleID: String?) -> Int? {
        guard isTrusted, !(bundleID.map(hidesSelection.contains) ?? false) else { return nil }
        let app = element(pid: pid, bundleID: bundleID, timeout: 0.3)
        guard let focused: AXUIElement = copy(app, kAXFocusedUIElementAttribute) else { return nil }
        if isSecure(focused) { return 0 }
        if let value: AXValue = copy(focused, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(value, .cfRange, &range) { return range.length }
        }
        if let markers: CFTypeRef = copy(focused, "AXSelectedTextMarkerRange") {
            var length: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(focused, "AXLengthForTextMarkerRange" as CFString, markers, &length) == .success {
                return (length as? Int) ?? (length as? NSNumber)?.intValue
            }
        }
        return nil
    }

    private static func element(pid: pid_t, bundleID: String?, timeout: Float) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        if let bundleID, chromiumLike.contains(bundleID) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return app
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        let role: String? = copy(element, kAXRoleAttribute)
        let subrole: String? = copy(element, kAXSubroleAttribute)
        return subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement) as? T
        }
        if T.self == AXValue.self, CFGetTypeID(value) == AXValueGetTypeID() {
            return (value as! AXValue) as? T
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

    /// `copyIfHidden`: when the app won't share its selection, copy it
    /// (launcher only; see SelectionCopier).
    static func capture(_ app: NSRunningApplication, copyIfHidden: Bool = false) async -> ScreenContext {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        var context = ScreenContext(appName: app.localizedName ?? "the app", bundleID: bundleID)
        let ax = await Task.detached(priority: .userInitiated) { AXReader.read(pid: pid, bundleID: bundleID) }.value
        context.needsAccessibility = !AXReader.isTrusted
        context.windowTitle = ax.title
        context.documentPath = ax.document
        var selection = ax.selection
        if selection == nil, copyIfHidden, AXReader.isTrusted,
           !ax.selectionKnown || bundleID.map(AXReader.hidesSelection.contains) == true {
            selection = await SelectionCopier.copySelection(from: app)
        }
        if let selection {
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
