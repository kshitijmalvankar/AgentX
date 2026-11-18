import AppKit
import SwiftUI

/// Claude showing you where something is: an AgentX pointer glides from your
/// mouse onto the spot and rings it for a few seconds. Display only: it never
/// clicks, and clicks pass straight through it.
@MainActor
final class PointerOverlay {
    static let shared = PointerOverlay()

    private var window: NSPanel?
    private let state = PointerState()
    private var hideTask: Task<Void, Never>?

    /// Point at `rect`, given in global coordinates with the origin at the
    /// top-left of the main screen (what Accessibility and ScreenCaptureKit use).
    func point(at rect: CGRect, label: String?) {
        let target = Self.cocoaRect(fromTopLeft: rect)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(target) }) ?? NSScreen.main else { return }
        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(screen.frame, display: false)
        // SwiftUI inside the window: origin at the screen's top-left, y down.
        let local = CGRect(x: target.minX - screen.frame.minX, y: screen.frame.maxY - target.maxY,
                           width: target.width, height: target.height)
        let mouse = NSEvent.mouseLocation
        var start = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        if !screen.frame.contains(mouse) { start = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2) }
        window.orderFrontRegardless()
        state.show(from: start, to: local, label: label)

        hideTask?.cancel()
        hideTask = Task { [state] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            state.hide()
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            window.orderOut(nil)
        }
    }

    /// Accessibility / ScreenCaptureKit rectangle → AppKit (origin bottom-left of the main screen).
    static func cocoaRect(fromTopLeft rect: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PointerOverlayView(state: state))
        return panel
    }
}

@MainActor
@Observable
final class PointerState {
    var tip = CGPoint.zero
    var target = CGRect.zero
    var label: String?
    var visible = false
    var arrived = false

    func show(from start: CGPoint, to rect: CGRect, label: String?) {
        self.label = label
        target = rect.insetBy(dx: -6, dy: -6)
        arrived = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { tip = start }
        withAnimation(.easeOut(duration: 0.15)) { visible = true }
        withAnimation(.spring(duration: 0.7, bounce: 0.2)) { tip = CGPoint(x: rect.midX, y: rect.midY) } completion: {
            withAnimation(.easeOut(duration: 0.25)) { self.arrived = true }
        }
    }

    func hide() {
        withAnimation(.easeIn(duration: 0.3)) { visible = false }
    }
}

private struct PointerOverlayView: View {
    let state: PointerState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.arrived {
                PulsingRing(rect: state.target)
                if let label = state.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor, in: .capsule)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        .fixedSize()
                        .position(x: state.target.midX, y: state.target.minY > 40 ? state.target.minY - 18 : state.target.maxY + 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            PointerArrow()
                .frame(width: 22, height: 30)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .position(x: state.tip.x + 11, y: state.tip.y + 15)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(state.visible ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// A ring around the target that breathes while it's shown.
private struct PulsingRing: View {
    let rect: CGRect
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(pulse ? 1.06 : 1)
            .shadow(color: Color.accentColor.opacity(0.6), radius: pulse ? 12 : 4)
            .position(x: rect.midX, y: rect.midY)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

/// AgentX's pointer: a classic arrow in the accent color with a white edge.
private struct PointerArrow: View {
    var body: some View {
        ArrowShape()
            .fill(Color.accentColor)
            .overlay(ArrowShape().stroke(.white, style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
    }

    private struct ArrowShape: Shape {
        func path(in r: CGRect) -> Path {
            let w = r.width / 22, h = r.height / 30
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + 24 * h))
            p.addLine(to: CGPoint(x: r.minX + 6.5 * w, y: r.minY + 18.5 * h))
            p.addLine(to: CGPoint(x: r.minX + 11 * w, y: r.minY + 28 * h))
            p.addLine(to: CGPoint(x: r.minX + 15 * w, y: r.minY + 26 * h))
            p.addLine(to: CGPoint(x: r.minX + 10.5 * w, y: r.minY + 16.5 * h))
            p.addLine(to: CGPoint(x: r.minX + 19 * w, y: r.minY + 16.5 * h))
            p.closeSubpath()
            return p
        }
    }
}
