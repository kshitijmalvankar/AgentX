import AppKit
import KeyboardShortcuts
import SwiftUI

/// A macOS keyboard shortcut that's switched on (Siri, Spotlight, input sources…).
struct SystemShortcut: Equatable, Sendable {
    let name: String
    let keyCode: Int
    /// Cocoa modifier flags (⇧⌃⌥⌘ only).
    let modifiers: UInt
}

/// Spots AgentX shortcuts that macOS also uses, like ⌥Space when it's Siri's
/// shortcut: one press then opens both. AgentX can't take a shortcut back from
/// macOS, so it says so and points at the setting to change.
enum ShortcutConflicts {
    static let modifierMask = NSEvent.ModifierFlags([.shift, .control, .option, .command]).rawValue

    /// What the IDs in com.apple.symbolichotkeys are (the ones near AgentX's shortcuts).
    static let knownNames: [String: String] = [
        "60": "Select the previous input source", "61": "Select the next input source",
        "64": "Spotlight", "65": "Finder search", "176": "Siri",
    ]

    /// Switched-on shortcuts in com.apple.symbolichotkeys (parameters: character, key code, modifiers).
    static func symbolicHotkeys(_ hotkeys: [String: Any]) -> [SystemShortcut] {
        hotkeys.compactMap { id, entry in
            guard let entry = entry as? [String: Any], (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
                  let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count == 3,
                  p[1] != 65_535 else { return nil }
            return SystemShortcut(name: knownNames[id] ?? "a macOS keyboard shortcut", keyCode: p[1],
                                  modifiers: UInt(p[2]) & modifierMask)
        }
    }

    /// Siri's keyboard shortcut (System Settings › Apple Intelligence & Siri), when it's a key combination.
    static func siri(_ siriDefaults: [String: Any]) -> SystemShortcut? {
        for key in ["CustomizedKeyboardShortcutSAE", "CustomizedKeyboardShortcut"] {
            guard let entry = siriDefaults[key] as? [String: Any],
                  (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
                  let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count == 3 else { continue }
            return SystemShortcut(name: "Siri", keyCode: p[1], modifiers: UInt(p[2]) & modifierMask)
        }
        return nil
    }

    /// macOS's shortcuts that are on, read from its settings.
    static func system() -> [SystemShortcut] {
        var all = symbolicHotkeys(UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:])
        if let siri = siri(UserDefaults(suiteName: "com.apple.Siri")?.dictionaryRepresentation() ?? [:]) { all.append(siri) }
        return all
    }

    /// The macOS shortcut that's the same key combination, if any (Siri first: it's the one people notice).
    static func clash(keyCode: Int, modifiers: NSEvent.ModifierFlags, in list: [SystemShortcut]) -> SystemShortcut? {
        let mods = modifiers.rawValue & modifierMask
        let same = list.filter { $0.keyCode == keyCode && $0.modifiers == mods }
        return same.first { $0.name == "Siri" } ?? same.first
    }

    @MainActor
    static func clash(for name: KeyboardShortcuts.Name) -> (shortcut: String, with: SystemShortcut)? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name),
              let other = clash(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.modifiers, in: system()) else { return nil }
        return ("\(shortcut)", other)
    }

    static func openSettings(for other: SystemShortcut) {
        let pane = other.name == "Siri" ? "com.apple.Siri-Settings.extension" : "com.apple.Keyboard-Settings.extension"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    }

    /// Once per clash: a notification saying both open and what to change.
    @MainActor
    static func warnOnce(defaults: UserDefaults = .standard) {
        for (name, feature) in [(KeyboardShortcuts.Name.toggleLauncher, "the launcher"), (.circleToAsk, "Circle to Ask")] {
            guard let clash = clash(for: name) else { continue }
            let key = "shortcutClashWarned.\(name.rawValue).\(clash.shortcut).\(clash.with.name)"
            guard !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            NotificationManager.shared.postNotice(
                title: "\(clash.shortcut) also opens \(clash.with.name)",
                body: "It's AgentX's shortcut for \(feature) and \(clash.with.name)'s in macOS, so both open. Change \(clash.with.name)'s in System Settings, or AgentX's in Settings › General.")
        }
    }
}

/// Under a shortcut recorder: says when macOS uses the same shortcut, with a way to fix it.
struct ShortcutClashNote: View {
    let name: KeyboardShortcuts.Name
    @State private var clash: (shortcut: String, with: SystemShortcut)?

    var body: some View {
        Group {
            if let clash {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(clash.shortcut) is also \(clash.with.name)'s shortcut, so both open. Pick another one here, or change \(clash.with.name)'s in System Settings.")
                        .font(.caption)
                    Spacer(minLength: 4)
                    Button("Open \(clash.with.name == "Siri" ? "Siri" : "Keyboard") Settings") { ShortcutConflicts.openSettings(for: clash.with) }
                        .controlSize(.small)
                }
            }
        }
        .onAppear(perform: check)
        // A new shortcut recorded here, or Siri's changed (both save to preferences).
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func check() {
        let now = ShortcutConflicts.clash(for: name)
        if now?.shortcut != clash?.shortcut || now?.with != clash?.with { clash = now }
    }
}
