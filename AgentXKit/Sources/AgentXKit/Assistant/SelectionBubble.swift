import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Select text in any app and a small AgentX button appears by the pointer.
/// Clicking it opens the launcher right there, with what you selected and
/// quick actions (Explain, Summarize, Fix the Writing…).
///
/// AgentX only notices where you release the mouse after dragging or
/// double-clicking, plus whether the app reports a selection (its length, not
/// its text). Nothing is read until you click the button. Never in password
/// managers or while a password field has the keyboard.
@MainActor
final class SelectionBubble {
    static let shared = SelectionBubble()

    nonisolated static let settingKey = "selectionBubble"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    private var monitors: [Any] = []
    private var panel: BubblePanel?
    private var downAt: NSPoint = .zero
    private var hideTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { SelectionBubble.shared.mouseDown(at: point) }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
            let point = NSEvent.mouseLocation, clicks = event.clickCount
            MainActor.assumeIsolated { SelectionBubble.shared.mouseUp(at: point, clicks: clicks) }
        }
        let scroll = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { SelectionBubble.shared.hide() }
        }
        monitors = [down, up, scroll].compactMap { $0 }
    }

    private func mouseDown(at point: NSPoint) {
        downAt = point
        hide()
    }

    private func mouseUp(at point: NSPoint, clicks: Int) {
        guard Self.isEnabled else { return }
        let dragged = hypot(point.x - downAt.x, point.y - downAt.y) > 6
        guard dragged || clicks >= 2,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier, !SelectionCopier.neverCopyFrom.contains(bundleID),
              !IsSecureEventInputEnabled() else { return }
        let pid = app.processIdentifier
        checkTask?.cancel()
        checkTask = Task {
            // Let the app finish selecting, then ask whether anything is selected.
            try? await Task.sleep(for: .milliseconds(120))
            let selected = await Task.detached(priority: .userInitiated) { AXReader.selectionLength(pid: pid, bundleID: bundleID) }.value
            // Show it when the app reports a selection, or can't say (Chrome and friends).
            guard !Task.isCancelled, selected.map({ $0 > 0 }) ?? AXReader.hidesSelection.contains(bundleID) else { return }
            self.show(near: point, app: app)
        }
    }

    private func show(near point: NSPoint, app: NSRunningApplication) {
        let size = NSSize(width: 74, height: 30)
        let panel = self.panel ?? BubblePanel(size: size) { SelectionBubble.shared.clicked() }
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: point.x + 10, y: point.y + 12)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self.hide()
        }
    }

    func hide() {
        checkTask?.cancel()
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }

    private func clicked() {
        let anchor = panel.map { NSPoint(x: $0.frame.minX, y: $0.frame.minY) } ?? NSEvent.mouseLocation
        hideTask?.cancel()
        panel?.orderOut(nil)
        LauncherController.shared.show(anchor: .point(anchor), fromSelection: true)
    }
}

/// The bubble's window: floats, never takes the keyboard or activates AgentX
/// (so the app you selected in stays in front), and takes the first click.
private final class BubblePanel: NSPanel {
    init(size: NSSize, action: @escaping @MainActor () -> Void) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = FirstClickHostingView(rootView: BubbleView(action: action))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct BubbleView: View {
    let action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("Ask", systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.mix(with: .purple, by: 0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .capsule
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .brightness(hovering ? 0.06 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Ask AgentX about what you selected")
        .padding(1)
    }
}
