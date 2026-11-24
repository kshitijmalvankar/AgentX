import SwiftUI

/// AgentX's shared shapes and button roles, so every surface matches.
///
/// Corners follow macOS 26's concentric model: a card's corners line up with
/// the window (or panel) around it when it sits near that container's
/// corner, and never get tighter than the card radius elsewhere.
enum Radius {
    /// Floating panels (the launcher).
    static let panel: CGFloat = 26
    /// Cards, banners and grouped boxes.
    static let card: CGFloat = 18
    /// Text fields and message bubbles.
    static let field: CGFloat = 18
    /// Small insets inside cards: code, diffs, output, hover highlights.
    static let inset: CGFloat = 8
}

extension Shape where Self == ConcentricRectangle {
    /// The card shape: concentric with its container, at least `Radius.card`.
    static var agentCard: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(Radius.card)), isUniform: true)
    }
}

extension View {
    /// The one main action in a view (New Session, Send, Allow, Save): tinted glass capsule.
    func primaryButton() -> some View {
        buttonStyle(.glassProminent).buttonBorderShape(.capsule)
    }

    /// Every other action (Cancel, Deny, Run Now, suggestions): clear glass capsule.
    func secondaryButton() -> some View {
        buttonStyle(.glass).buttonBorderShape(.capsule)
    }

    /// A glass card surface in the shared card shape.
    func cardSurface(tint: Color? = nil) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .agentCard)
    }
}

/// Lays children out left to right, wrapping onto new lines (suggestion chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// Dashboard cards in rows that fill the width: as many columns as fit (each at least
/// `minimum` wide), never more columns than cards, and no card left alone on a row when
/// that can be avoided (four cards make two rows of two). Each row is as tall as its
/// tallest card. Not lazy: a handful of cards, and its height is always exact.
struct CardGrid: Layout {
    var minimum: CGFloat = 340
    var spacing: CGFloat = 16

    func columns(for width: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 1 }
        var columns = min(count, max(1, Int((width + spacing) / (minimum + spacing))))
        if columns > 2, count % columns == 1 { columns -= 1 }
        return columns
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum * 2 + spacing
        let heights = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(for: bounds.width, count: subviews.count)
        let width = columnWidth(bounds.width, columns)
        var y = bounds.minY
        for (row, height) in rowHeights(width: bounds.width, subviews: subviews).enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing), y: y),
                                      proposal: ProposedViewSize(width: width, height: height))
            }
            y += height + spacing
        }
    }

    private func columnWidth(_ total: CGFloat, _ columns: Int) -> CGFloat {
        max(0, (total - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let columns = columns(for: width, count: subviews.count)
        let column = columnWidth(width, columns)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            (start..<min(start + columns, subviews.count))
                .map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
                .max() ?? 0
        }
    }
}
