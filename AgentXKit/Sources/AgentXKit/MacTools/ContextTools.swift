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
            return ToolOutput(text: "A picture of \(picture.appName)'s window\(title) (\(Int(picture.imageSize.width))×\(Int(picture.imageSize.height)) pixels).",
                              image: ToolImage(data: picture.jpeg, mediaType: "image/jpeg"))
        },
        MacTool("screen_point", area: "Screen", summary: "Point at something on screen", risk: .read,
                description: "Show the user where something is: AgentX moves a pointer onto it and rings it for a few seconds. It never clicks. Pass `target`, the visible label of a button, menu, tab or field in the app they were last using. For something inside a web page or a picture, look first (screen_look, or a picture they attached) and pass `x` and `y` in that picture's pixels instead.",
                parameters: [
                    .init("target", .string, "The visible label to point at, e.g. \"Export…\" or \"Share\".", required: false),
                    .init("x", .number, "Pixels from the left of the last picture of their screen.", required: false),
                    .init("y", .number, "Pixels from the top of that picture.", required: false),
                    .init("note", .string, "A few words to show by the pointer, e.g. \"Click here to export\".", required: false),
                ],
                untrustedSource: "another app's interface", attendedOnly: true) { args in
            let note = args.optionalString("note")
            if let x = args.values["x"]?.number, let y = args.values["y"]?.number {
                let spot = await MainActor.run { ScreenGrabber.lastLook.flatMap { ScreenTargets.spot(x: x, y: y, in: $0) } }
                guard let spot else { throw ToolError("There's no picture of the screen to point into (or the spot is outside it). Call screen_look first.") }
                await MainActor.run { PointerOverlay.shared.point(at: spot, label: note) }
                return "Pointed at that spot."
            }
            guard let target = args.optionalString("target") else { throw ToolError("Pass `target` (a label) or `x` and `y`.") }
            guard AXReader.isTrusted else {
                throw ToolError("AgentX needs Accessibility to find things on screen. The user can allow it in Settings → Assistant → What's on your screen.")
            }
            guard let app = await MainActor.run(body: { FrontmostTracker.shared.lastApp }) else {
                throw ToolError("No other app has been in front yet.")
            }
            let pid = app.processIdentifier
            let found = await Task.detached(priority: .userInitiated) { ScreenTargets.find(target, pid: pid) }.value
            // Not in Accessibility (web pages, pictures): find the words on screen with Vision, on this Mac.
            if found.best == nil, ScreenGrabber.hasPermission, let spot = try? await ScreenText.locate(target, in: app) {
                await MainActor.run { PointerOverlay.shared.point(at: spot, label: note ?? target) }
                return "Pointed at “\(target)” (found by reading the window) in \(app.localizedName ?? "the app")."
            }
            guard let match = found.best else {
                let seen = found.seen.isEmpty ? "" : " Labels there include: " + found.seen.prefix(30).map { "“\($0)”" }.joined(separator: ", ") + "."
                throw ToolError("Couldn't find “\(target)” in \(app.localizedName ?? "that app").\(seen) For web pages and pictures, use screen_look and pass x and y.")
            }
            await MainActor.run { PointerOverlay.shared.point(at: match.frame, label: note ?? match.label) }
            return "Pointed at “\(match.label)” (\(match.role.replacingOccurrences(of: "AX", with: "").lowercased())) in \(app.localizedName ?? "the app")."
        },
    ]}
}
