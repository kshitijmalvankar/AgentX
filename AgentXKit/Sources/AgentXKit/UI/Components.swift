import SwiftUI

/// A Liquid Glass dashboard card with a title row.
struct GlassCard<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    /// The icon badge's colour (each kind of card has its own).
    var tint: Color
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, tint: Color = .accentColor,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconBadge(symbol: symbol, tint: tint)
                Text(title).font(.headline)
                Spacer()
                accessory
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular.interactive(), in: .agentCard)
    }
}

/// A symbol on a small tinted rounded square, like System Settings' icons.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: tint.opacity(0.35), radius: 3, y: 1)
    }
}

/// Small colored capsule showing a live session's state.
struct StateBadge: View {
    let state: LiveState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: state == .running || state == .waiting)
    }

    private var color: Color {
        switch state {
        case .starting, .running: .blue
        case .waiting: .orange
        case .idle: .green
        case .ended: .secondary
        }
    }
}

/// "Coming in M2" style placeholder for features not built yet.
struct ComingSoonView: View {
    let item: SidebarItem
    let milestone: String
    let blurb: String

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.symbol)
        } description: {
            Text(blurb)
        } actions: {
            Text("Planned for \(milestone)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
}

extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
