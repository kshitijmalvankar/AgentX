import AppKit
import KeyboardShortcuts
@preconcurrency import ScreenCaptureKit
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Circle to Ask. AgentX Dev adds ⌃ so it doesn't fight the installed app.
    static let circleToAsk = Self("circleToAsk", initial: AppChannel.current.isDev
        ? .init(.space, modifiers: [.control, .option, .shift])
        : .init(.space, modifiers: [.option, .shift]))
}

/// Circle to Ask: press the shortcut, the screen glows, and you circle
/// anything (a paragraph you're reading, a chart, an error message). AgentX
/// reads what's inside on this Mac (Vision) and opens the launcher next to it
/// with the text attached and the quick actions: Explain, Summarize,
/// Translate… or your own question. Needs Screen Recording. Nothing is read
/// until you let go, and only the circled area.
@MainActor
final class CircleToAsk {
    static let shared = CircleToAsk()

    private var panels: [CirclePanel] = []
    private var app: NSRunningApplication?
    private(set) var isActive = false

    static func registerHotkey() {
        KeyboardShortcuts.onKeyUp(for: .circleToAsk) {
            MainActor.assumeIsolated { CircleToAsk.shared.toggle() }
        }
    }

    func toggle() {
        if isActive { cancel() } else { start() }
    }

    func start() {
        guard ScreenGrabber.hasPermission else {
            ScreenGrabber.requestPermission()
            LauncherController.shared.show()
            LauncherController.shared.error = "Circle to Ask needs Screen Recording to read what you circle. Turn it on for AgentX in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
            return
        }
        LauncherController.shared.hide()
        let front = NSWorkspace.shared.frontmostApplication
        app = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? FrontmostTracker.shared.lastApp : front
        isActive = true
        panels = NSScreen.screens.map { screen in
            let panel = CirclePanel(screen: screen) { [weak self] points, screen in
                Task { await self?.finish(points, on: screen) }
            } cancel: { [weak self] in
                self?.cancel()
            }
            panel.orderFrontRegardless()
            return panel
        }
        // The one under the pointer takes the keyboard (Esc), without making AgentX the active app.
        let mouse = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
        NSCursor.crosshair.push()
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        NSCursor.pop()
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    /// You let go: read the circled area and open the launcher by it.
    private func finish(_ points: [CGPoint], on screen: NSScreen) async {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        guard let region = Self.region(of: points, screenFrame: screen.frame, mainHeight: mainHeight) else { return }
        let app = self.app
        // Let the circle show for a moment, then get the glow out of the picture.
        try? await Task.sleep(for: .milliseconds(180))
        cancel()
        try? await Task.sleep(for: .milliseconds(120))
        do {
            let image = try await SCScreenshotManager.captureImage(in: region)
            let text = await Task.detached(priority: .userInitiated) { ScreenText.text(in: image) }.value
            let picture = Self.wantsPicture(text: text) ? Self.picture(of: image, app: app) : nil
            LauncherController.shared.showCircled(text: text, picture: picture, from: app, near: region)
        } catch {
            LauncherController.shared.show()
            LauncherController.shared.error = "Couldn't read the circled area: \(error.localizedDescription)"
        }
    }

    // MARK: Pure parts (tested)

    /// The circled area in global coordinates (origin at the top-left of the main
    /// screen, what ScreenCaptureKit uses), from points in a screen's overlay (origin
    /// at that screen's top-left). Nil when it's too small to mean anything.
    nonisolated static func region(of points: [CGPoint], screenFrame: CGRect, mainHeight: CGFloat) -> CGRect? {
        guard let first = points.first else { return nil }
        var box = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        guard box.width >= 16 || box.height >= 16 else { return nil }
        box = box.insetBy(dx: -8, dy: -8).intersection(CGRect(origin: .zero, size: screenFrame.size))
        // The overlay's top is the screen's top: screenFrame.maxY in AppKit, mainHeight - maxY from the top.
        return CGRect(x: screenFrame.minX + box.minX, y: mainHeight - screenFrame.maxY + box.minY,
                      width: box.width, height: box.height)
    }

    /// Little or no text (a chart, a photo, an icon): send the picture so Claude can see it.
    nonisolated static func wantsPicture(text: String) -> Bool {
        text.filter { !$0.isWhitespace }.count < 40
    }

    private static func picture(of image: CGImage, app: NSRunningApplication?) -> ScreenGrabber.Picture? {
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        return ScreenGrabber.Picture(jpeg: jpeg, windowTitle: nil, appName: app?.localizedName ?? "your screen",
                                     imageSize: CGSize(width: image.width, height: image.height), caption: "What you circled")
    }
}

// MARK: - Overlay

/// One per screen: a glow around the edges, a glowing ring at the pointer, and
/// the circle you draw. Takes the mouse and Esc while it's up; never activates AgentX.
private final class CirclePanel: NSPanel {
    private let cancelHandler: @MainActor () -> Void

    init(screen: NSScreen, done: @escaping @MainActor ([CGPoint], NSScreen) -> Void, cancel: @escaping @MainActor () -> Void) {
        cancelHandler = cancel
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setFrame(screen.frame, display: false)
        contentView = NSHostingView(rootView: CircleOverlayView { points in done(points, screen) })
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancelHandler() }
    override func rightMouseDown(with event: NSEvent) { cancelHandler() }
}

private struct CircleOverlayView: View {
    let done: @MainActor ([CGPoint]) -> Void
    @State private var points: [CGPoint] = []
    @State private var pointer: CGPoint?
    @State private var finished = false
    @State private var spin = false

    /// Apple Intelligence-like colours.
    private static let glow = AngularGradient(colors: [.blue, .purple, .pink, .orange, .yellow, .cyan, .blue], center: .center)

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
            // The edges glow while it's waiting for you.
            Rectangle()
                .strokeBorder(Self.glow, lineWidth: 6)
                .blur(radius: 10)
                .hueRotation(.degrees(spin ? 360 : 0))
                .allowsHitTesting(false)
            Text(points.isEmpty ? "Circle anything to ask about it  ·  Esc to cancel" : "Let go to ask")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)
                .allowsHitTesting(false)
            if points.count > 1 {
                stroke
            }
            if let pointer, !finished {
                Circle()
                    .strokeBorder(Self.glow, lineWidth: 3)
                    .frame(width: 30, height: 30)
                    .shadow(color: .purple.opacity(0.8), radius: 8)
                    .hueRotation(.degrees(spin ? 360 : 0))
                    .position(pointer)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(.rect)
        .onContinuousHover { phase in
            if case .active(let p) = phase { pointer = p }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard !finished else { return }
                    pointer = value.location
                    if let last = points.last, hypot(last.x - value.location.x, last.y - value.location.y) < 2 { return }
                    points.append(value.location)
                }
                .onEnded { _ in
                    guard !finished else { return }
                    if CircleToAsk.region(of: points, screenFrame: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), mainHeight: 10_000) == nil {
                        points = []   // a click or a tiny scribble: try again
                        return
                    }
                    finished = true
                    done(points)
                }
        )
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { spin = true }
        }
    }

    private var stroke: some View {
        let path = Path { p in
            p.addLines(points)
            if finished { p.closeSubpath() }
        }
        return ZStack {
            if finished { path.fill(.white.opacity(0.12)) }
            path.stroke(Self.glow, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)).blur(radius: 8)
            path.stroke(Self.glow, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}
