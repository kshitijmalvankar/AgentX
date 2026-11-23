import AppKit
import Testing
@testable import AgentXKit

@Suite("Shortcut clashes with macOS")
struct ShortcutConflictTests {
    // As macOS stores them: [character, key code, Cocoa modifier flags]. 49 is Space; 524288 is ⌥.
    private let hotkeys: [String: Any] = [
        "60": ["enabled": false, "value": ["parameters": [32, 49, 262_144], "type": "standard"]],
        "176": ["enabled": true, "value": ["parameters": [32, 49, 524_288], "type": "SAE1.0"]],
        "79": ["enabled": true, "value": ["parameters": [65_535, 123, 8_650_752], "type": "standard"]],
    ]

    @Test func siriOnOptionSpaceClashesWithTheLauncher() throws {
        let list = ShortcutConflicts.symbolicHotkeys(hotkeys)
        #expect(!list.contains { $0.name == "Select the previous input source" }, "switched off: no clash")
        let clash = try #require(ShortcutConflicts.clash(keyCode: 49, modifiers: [.option], in: list))
        #expect(clash.name == "Siri")
        #expect(ShortcutConflicts.clash(keyCode: 49, modifiers: [.control, .option], in: list) == nil, "AgentX Dev's ⌃⌥Space is free")
        #expect(ShortcutConflicts.clash(keyCode: 49, modifiers: [.option, .shift], in: list) == nil, "Circle to Ask's ⌥⇧Space is free")
    }

    @Test func siriOwnSettingCountsToo() throws {
        let siri = try #require(ShortcutConflicts.siri([
            "CustomizedKeyboardShortcutSAE": ["enabled": 1, "value": ["parameters": [32, 49, 524_288], "type": "SAE1.0"]],
        ]))
        #expect(siri == SystemShortcut(name: "Siri", keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue))
        #expect(ShortcutConflicts.siri(["CustomizedKeyboardShortcutSAE": ["enabled": 0, "value": ["parameters": [32, 49, 524_288]]]]) == nil,
                "Siri's shortcut switched off")
    }

    @Test func extraFlagsLikeFunctionDontMatter() {
        // Arrow keys carry the numeric-pad and function flags: only ⇧⌃⌥⌘ are compared.
        let list = ShortcutConflicts.symbolicHotkeys(hotkeys)
        #expect(ShortcutConflicts.clash(keyCode: 123, modifiers: [.control], in: list)?.name == "a macOS keyboard shortcut")
    }
}
