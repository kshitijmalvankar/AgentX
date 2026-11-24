import SwiftUI

/// AgentX's motion: small, quick and springy, and calm when you've asked macOS to
/// reduce motion (then things fade instead of moving).
enum Motion {
    /// Things arriving: cards, messages, approvals.
    static let arrive = Animation.spring(duration: 0.26, bounce: 0.08)
    /// Hover and selection: snappy, never in the way.
    static let quick = Animation.snappy(duration: 0.12)
    /// Numbers and gauges settling.
    static let settle = Animation.spring(duration: 0.5, bounce: 0.05)
}

extension View {
    /// Fades and rises into place the first time it appears, `delay` seconds later
    /// (cards on the dashboard arrive one after another).
    func arrives(delay: Double = 0, distance: CGFloat = 8, enabled: Bool = true) -> some View {
        modifier(ArriveModifier(delay: delay, distance: distance, enabled: enabled))
    }
}

private struct ArriveModifier: ViewModifier {
    let delay: Double
    let distance: CGFloat
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Not enabled: it's simply there (a message that was already in the conversation).
    init(delay: Double, distance: CGFloat, enabled: Bool) {
        self.delay = delay
        self.distance = distance
        _shown = State(initialValue: !enabled)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : Motion.arrive.delay(delay)) { shown = true }
            }
    }
}

/// "Working…" with a light sweeping across it, like the Claude app, and the dots counting.
struct WorkingIndicator: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.8) / 1.8)
            HStack(spacing: 8) {
                SparkleMark(spinning: !reduceMotion, time: t)
                Text(text)
                    .foregroundStyle(.tertiary)
                    .overlay {
                        if !reduceMotion {
                            LinearGradient(stops: [.init(color: .clear, location: phase - 0.25),
                                                   .init(color: .primary.opacity(0.85), location: phase),
                                                   .init(color: .clear, location: phase + 0.25)],
                                           startPoint: .leading, endPoint: .trailing)
                                .mask(Text(text))
                        }
                    }
            }
        }
        .font(.callout)
        .accessibilityLabel(text)
    }
}

/// Claude's spark, turning slowly while it works.
private struct SparkleMark: View {
    let spinning: Bool
    let time: TimeInterval

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.orange.gradient)
            .rotationEffect(.degrees(spinning ? (time * 90).truncatingRemainder(dividingBy: 360) : 0))
            .scaleEffect(spinning ? 0.9 + 0.12 * sin(time * 3) : 1)
    }
}

/// A gauge ring that fills up to its value when it appears, and glides when it changes.
struct AnimatedRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 7
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.01, min(1, shown)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(reduceMotion ? nil : Motion.settle.delay(0.15)) { shown = fraction } }
        .onChange(of: fraction) { _, value in withAnimation(Motion.settle) { shown = value } }
    }
}
