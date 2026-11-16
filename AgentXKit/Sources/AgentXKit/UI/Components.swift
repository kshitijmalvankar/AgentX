import SwiftUI

/// A Liquid Glass dashboard card with a title row.
struct GlassCard<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .agentCard)
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
