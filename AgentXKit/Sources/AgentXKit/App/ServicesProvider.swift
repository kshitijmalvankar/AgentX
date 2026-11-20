import AppKit

/// AgentX in every app's Services menu (right-click, or the app menu → Services):
/// - **Ask AgentX** with selected text: the launcher opens with it attached, with
///   the same quick actions as the selection bubble.
/// - **Summarize with AgentX**: summarized on this Mac (Apple's on-device model).
/// - **Ask AgentX About These Files** in Finder.
///
/// The services are listed in App/Info.plist (NSServices); macOS calls these methods.
@MainActor
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    static func register() {
        NSApp.servicesProvider = shared
        // Pick up the Info.plist entries right away, not after the next login.
        NSUpdateDynamicServices()
    }

    @objc func askAgentX(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pasteboard.string(forType: .string)
        let files = Self.files(on: pasteboard)
        guard text?.isEmpty == false || !files.isEmpty else {
            error.pointee = "There was nothing selected to send to AgentX."
            return
        }
        LauncherController.shared.showShared(text: text, files: files)
    }

    @objc func summarizeWithAgentX(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "There was no text selected to summarize."
            return
        }
        let summarize = LauncherController.selectionActions.first { $0.job == .summarize }
        LauncherController.shared.showShared(text: text, files: [], job: .summarize,
                                             claudePrompt: summarize?.prompt ?? "Summarize this in a few short bullet points.")
    }

    @objc func askAboutFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = Self.files(on: pasteboard)
        guard !files.isEmpty else {
            error.pointee = "There were no files selected."
            return
        }
        LauncherController.shared.showShared(text: nil, files: files)
    }

    private static func files(on pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.path)
    }
}
