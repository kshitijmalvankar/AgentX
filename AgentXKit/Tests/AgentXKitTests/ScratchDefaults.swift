import Foundation

/// A settings store for one test, kept in a temporary folder: a suite named
/// with an absolute path stores its plist at that path, so tests never touch
/// AgentX's real settings or leave files in ~/Library/Preferences. The folder
/// is made only when a test uses it; call `remove()` when the test ends.
final class ScratchDefaults: @unchecked Sendable {
    let folder: URL
    private var store: UserDefaults?

    init(_ prefix: String = "agentx-tests") {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    var defaults: UserDefaults {
        if let store { return store }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let made = UserDefaults(suiteName: folder.appendingPathComponent("defaults").path)!
        store = made
        return made
    }

    func remove() {
        // Finish any pending save first, or it recreates the folder afterwards.
        store?.synchronize()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A port for a test listener, outside the range macOS hands out for
/// outgoing connections (49152+). With port 0 the listener could get a port
/// a previous test's client just used, and connecting would then reverse a
/// connection macOS still remembers: "Address already in use".
func testListenerPort() -> UInt16 { UInt16.random(in: 20_000..<40_000) }
