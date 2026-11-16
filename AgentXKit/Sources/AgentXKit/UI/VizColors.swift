import AppKit
import SwiftUI

/// Chart colors. Categorical slots 1-3 and the status palette come from the
/// validated reference palette; light and dark are separately chosen steps,
/// checked against macOS window surfaces (#ececec light, #1e1e1e dark).
/// Light orange/aqua sit under 3:1 contrast, so every chart that uses them
/// also shows labelled values (the "relief rule").
enum Viz {
    // Categorical, fixed order: never cycled, always following the entity.
    static let series1 = dynamic(light: 0x2A78D6, dark: 0x3987E5)  // blue
    static let series2 = dynamic(light: 0xEB6834, dark: 0xD95926)  // orange
    static let series3 = dynamic(light: 0x1BAF7A, dark: 0x199E70)  // aqua

    /// Single-hue magnitude (per-core bars, capacity bars).
    static let sequential = series1
    /// Unfilled part of a capacity bar.
    static let track = Color.secondary.opacity(0.18)

    // Status: reserved for state, always shown with an icon and a label.
    static let good = Color(hex: 0x0CA30C)
    static let warning = Color(hex: 0xFAB219)
    static let serious = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// A state shown with color, an icon and a word, never color alone.
/// The icon wears the status color; the text stays in the normal text color.
struct StatusLabel: View {
    enum Level { case good, warning, serious, critical }
    let level: Level
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.16), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch level {
        case .good: "checkmark.circle.fill"
        case .warning, .serious: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch level {
        case .good: Viz.good
        case .warning: Viz.warning
        case .serious: Viz.serious
        case .critical: Viz.critical
        }
    }
}
