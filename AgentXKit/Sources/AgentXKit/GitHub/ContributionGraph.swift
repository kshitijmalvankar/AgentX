import AppKit
import SwiftUI

/// GitHub's green contribution calendar: one square per day, weeks as
/// columns (Sunday on top). Shows as many recent weeks as fit the width.
struct ContributionGraph: View {
    let calendar: ContributionCalendar
    var cell: CGFloat = 11
    var gap: CGFloat = 3
    var showsLegend = true

    private let dayLabelWidth: CGFloat = 26
    private let monthLabelHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let fit = max(1, Int((geo.size.width - dayLabelWidth + gap) / (cell + gap)))
                let weeks = Array(calendar.weeks.suffix(fit))
                VStack(alignment: .leading, spacing: 3) {
                    monthLabels(weeks)
                    HStack(alignment: .top, spacing: gap) {
                        dayLabels
                        ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                            weekColumn(week, isFirst: index == 0)
                        }
                    }
                }
            }
            .frame(height: monthLabelHeight + 3 + 7 * cell + 6 * gap)

            if showsLegend {
                HStack(spacing: 4) {
                    Text("\(calendar.total) contributions in the last year")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Less").foregroundStyle(.tertiary)
                    ForEach(0..<5) { level in square(level) }
                    Text("More").foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(calendar.total) contributions in the last year; current streak \(calendar.currentStreak) days")
    }

    private func weekColumn(_ week: [ContributionDay], isFirst: Bool) -> some View {
        VStack(spacing: gap) {
            // A partial first week starts part-way down, so weekdays line up.
            if isFirst, let first = week.first {
                ForEach(0..<(weekday(first.date)), id: \.self) { _ in Color.clear.frame(width: cell, height: cell) }
            }
            ForEach(week) { day in
                square(day.level)
                    .help("\(day.count == 0 ? "No" : "\(day.count)") contribution\(day.count == 1 ? "" : "s") on \(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
            }
        }
    }

    private func square(_ level: Int) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(ContributionColors.color(for: level))
            .frame(width: cell, height: cell)
    }

    private var dayLabels: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<7) { row in
                Text(row == 1 ? "Mon" : row == 3 ? "Wed" : row == 5 ? "Fri" : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: dayLabelWidth - gap, height: cell, alignment: .leading)
            }
        }
    }

    /// Month names above the first week that starts in that month.
    private func monthLabels(_ weeks: [[ContributionDay]]) -> some View {
        HStack(spacing: gap) {
            Color.clear.frame(width: dayLabelWidth - gap, height: monthLabelHeight)
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                let month = week.first.map { Calendar.current.component(.month, from: $0.date) }
                let previous = index > 0 ? weeks[index - 1].first.map { Calendar.current.component(.month, from: $0.date) } : nil
                ZStack(alignment: .leading) {
                    Color.clear
                    if let first = week.first, month != previous, index < weeks.count - 1 {
                        Text(first.date.formatted(.dateTime.month(.abbreviated)))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .frame(width: cell, height: monthLabelHeight)
            }
        }
    }

    private func weekday(_ date: Date) -> Int {
        Calendar(identifier: .gregorian).component(.weekday, from: date) - 1   // Sunday = 0
    }
}

/// GitHub's contribution greens (one hue, light → dark), chosen per appearance.
enum ContributionColors {
    private static let light: [UInt32] = [0xEBEDF0, 0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
    private static let dark: [UInt32] = [0x2D333B, 0x0E4429, 0x006D32, 0x26A641, 0x39D353]

    static func color(for level: Int) -> Color {
        let i = min(4, max(0, level))
        return Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark[i] : light[i])
        })
    }
}
