import AppKit
import Carbon.HIToolbox

/// The fallback for apps that won't share their selection through
/// Accessibility (Chrome and other Chromium browsers): press ⌘C in that app
/// only, read the text, and put your clipboard back right away.
///
/// Only when you open the launcher and the app is in front. Never while a
/// password field has the keyboard (secure input), never in Finder (⌘C copies
/// files there) or password managers, and off in Settings → Assistant if you
/// prefer. If nothing is selected the app copies nothing and your clipboard is
/// never touched.
@MainActor
enum SelectionCopier {
    nonisolated static let settingKey = "contextCopyFallback"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// Apps AgentX never presses ⌘C in.
    nonisolated static let neverCopyFrom: Set<String> = [
        "com.apple.finder", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop",
    ]

    /// The selected text in `app`, copied and then cleared from the clipboard, or nil.
    static func copySelection(from app: NSRunningApplication, pasteboard: NSPasteboard = .general) async -> String? {
        guard isEnabled, let bundleID = app.bundleIdentifier, !neverCopyFrom.contains(bundleID),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.isActive,
              !IsSecureEventInputEnabled(), CGPreflightPostEventAccess() else { return nil }
        let saved = Snapshot(pasteboard)
        let before = pasteboard.changeCount
        guard press(CGKeyCode(kVK_ANSI_C), in: app.processIdentifier) else { return nil }
        for _ in 0..<30 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.restore(to: pasteboard)
        return text?.isEmpty == false ? text : nil
    }

    /// Paste `text` into `app` (⌘V sent to that app only), then put your
    /// clipboard back. For Replace Selection, which you click.
    static func paste(_ text: String, into app: NSRunningApplication, pasteboard: NSPasteboard = .general) async -> Bool {
        guard !IsSecureEventInputEnabled(), CGPreflightPostEventAccess() else { return false }
        let saved = Snapshot(pasteboard)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Snapshot.transient)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        guard press(CGKeyCode(kVK_ANSI_V), in: app.processIdentifier) else {
            saved.restore(to: pasteboard)
            return false
        }
        // Give the app time to read the clipboard before it's put back.
        try? await Task.sleep(for: .milliseconds(500))
        saved.restore(to: pasteboard)
        return true
    }

    /// ⌘ plus a key, sent to one app. A private event source, so modifier keys
    /// you may still be holding (from the shortcut) don't mix in.
    private static func press(_ key: CGKeyCode, in pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// Everything on a clipboard (every type of every item), to put back.
    struct Snapshot {
        /// nspasteboard.org: tells clipboard-history apps not to record it as a new copy.
        nonisolated static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored = items.filter { !$0.isEmpty }.map { pairs in
                let item = NSPasteboardItem()
                for pair in pairs { item.setData(pair.data, forType: pair.type) }
                item.setData(Data(), forType: Self.transient)
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }
}
