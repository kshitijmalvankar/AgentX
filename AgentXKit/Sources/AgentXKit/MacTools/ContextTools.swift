import AppKit
import Foundation

/// "What am I looking at?" tools. Only for conversations you're in
/// (attendedOnly), never for scheduled or triggered runs. Both count as
/// untrusted content, since the screen can show anything.
enum ContextTools {
    static var all: [MacTool] {[
        MacTool("context_now", area: "Screen", summary: "See what you're working on", risk: .read,
                description: "The app the user was last using (other than AgentX): its window title, document, selected text, browser tab or Finder selection. Use when they say \"this\" or \"what I'm looking at\".",
                untrustedSource: "what's on your screen", attendedOnly: true) { _ in
            guard let app = await MainActor.run(body: { FrontmostTracker.shared.lastApp }) else {
                throw ToolError("No other app has been in front yet.")
            }
            let context = await ContextCapture.capture(app)
            var text = context.promptBlock()
            if context.needsAccessibility { text += "\n(AgentX can't read windows or selections until the user allows Accessibility in Settings → Assistant → Permissions.)" }
            if let blocked = context.automationBlocked { text += "\n(AgentX isn't allowed to read \(blocked); see Settings → Assistant → Permissions.)" }
            if let withheld = context.selectionWithheld { text += "\n(The selected text looked like \(withheld), so it wasn't included.)" }
            return text
        },
        MacTool("screen_look", area: "Screen", summary: "Look at a window", risk: .ask,
                description: "Take a picture of the front window of the app the user was last using, to see what words can't describe (images, charts, layouts, PDFs). Asks the user every time. Prefer context_now when text is enough.",
                untrustedSource: "a screenshot of your screen", attendedOnly: true) { _ in
            guard let app = await MainActor.run(body: { FrontmostTracker.shared.lastApp }) else {
                throw ToolError("No other app has been in front yet.")
            }
            let picture = try await ScreenGrabber.captureFrontWindow(of: app)
            let title = picture.windowTitle.map { " “\($0)”" } ?? ""
            return ToolOutput(text: "A picture of \(picture.appName)'s window\(title).", image: ToolImage(data: picture.jpeg, mediaType: "image/jpeg"))
        },
    ]}
}
