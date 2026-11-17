import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Stop every running Claude session and pause automations. Changeable in Settings → Security.
    static let stopEverything = Self("stopEverything", initial: .init(.period, modifiers: [.control, .option, .command]))
}

/// "Stop everything", from the menu bar, Settings, the hotkey or a tokenized link.
@MainActor
enum KillSwitch {
    static func registerHotkey() {
        KeyboardShortcuts.onKeyUp(for: .stopEverything) {
            MainActor.assumeIsolated { _ = Task { await AppModel.shared.stopEverything(source: "the keyboard shortcut") } }
        }
    }
}
