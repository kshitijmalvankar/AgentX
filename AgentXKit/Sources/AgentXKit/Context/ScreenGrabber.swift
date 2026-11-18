import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// A picture of one app's front window, taken only when you click the eye
/// button in the launcher or approve Claude's screen_look. Needs Screen
/// Recording permission (System Settings › Privacy & Security). The picture
/// goes to Claude with your message, nowhere else, and isn't saved.
enum ScreenGrabber {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask macOS (shows the prompt the first time; after that, opens nothing).
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Claude reads images best up to about this many pixels on the long side.
    static let maxDimension: CGFloat = 1568

    struct Picture: Sendable {
        var jpeg: Data
        var windowTitle: String?
        var appName: String
        /// Where the window was (global, origin top-left of the main screen) and the picture's size in pixels.
        var windowFrame: CGRect = .zero
        var imageSize: CGSize = .zero
    }

    /// The last picture's geometry, so screen_point can turn a spot in it into a place on screen.
    struct LastLook: Sendable {
        var windowFrame: CGRect
        var imageSize: CGSize
        var appName: String
    }

    @MainActor static var lastLook: LastLook?

    static func captureFrontWindow(of app: NSRunningApplication) async throws -> Picture {
        guard hasPermission else {
            requestPermission()
            throw ToolError("AgentX needs Screen Recording permission to see a window. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen AgentX.")
        }
        let pid = app.processIdentifier
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60
        }
        // Prefer the window macOS says is focused; otherwise the biggest one.
        let focusedTitle = AXReader.read(pid: pid, bundleID: app.bundleIdentifier).title
        guard let window = candidates.first(where: { focusedTitle != nil && $0.title == focusedTitle })
                ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw ToolError("\(app.localizedName ?? "That app") has no window on screen to look at.")
        }
        let config = SCStreamConfiguration()
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        var width = window.frame.width * scale, height = window.frame.height * scale
        let shrink = min(1, maxDimension / max(width, height))
        width *= shrink
        height *= shrink
        config.width = Int(width)
        config.height = Int(height)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ToolError("Couldn't encode the picture.")
        }
        let picture = Picture(jpeg: jpeg, windowTitle: window.title, appName: app.localizedName ?? "the app",
                              windowFrame: window.frame, imageSize: CGSize(width: image.width, height: image.height))
        await MainActor.run { lastLook = LastLook(windowFrame: picture.windowFrame, imageSize: picture.imageSize, appName: picture.appName) }
        return picture
    }
}
