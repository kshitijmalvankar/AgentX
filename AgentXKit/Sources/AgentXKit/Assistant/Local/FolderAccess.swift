import AppKit
import Foundation

/// macOS hides Desktop, Documents and Downloads from an app (Spotlight
/// results included) until you allow it, under Privacy & Security › Files &
/// Folders. AgentX asks when you search one of them: the first look at the
/// folder shows macOS's prompt.
enum FolderAccess {
    enum Folder: String, CaseIterable, Identifiable, Sendable {
        case desktop = "Desktop", documents = "Documents", downloads = "Downloads"
        var id: String { rawValue }
        var url: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(rawValue) }
    }

    /// Whether AgentX can see the folder. The first time, macOS asks you (this waits for your answer).
    static func ensure(_ folder: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
        }.value
    }

    /// Where screenshots are saved (Desktop unless you changed it in the Screenshot app).
    static var screenshotFolder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return custom.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Folder.desktop.url
    }

    /// The folder a file search needs to see, if it's a protected one.
    static func folder(for find: LocalPlan) -> URL? {
        if find.fileKind == "screenshot" { return screenshotFolder }
        switch find.folder {
        case "desktop": return Folder.desktop.url
        case "documents": return Folder.documents.url
        case "downloads": return Folder.downloads.url
        default: return nil
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }
}
