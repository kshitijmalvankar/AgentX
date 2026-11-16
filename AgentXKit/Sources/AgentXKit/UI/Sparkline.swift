import Charts
import SwiftUI

/// One value of one series at one moment.
struct SparkPoint: Identifiable {
    let date: Date
    let series: String
    let value: Double
    var id: String { "\(series)-\(date.timeIntervalSinceReferenceDate)" }
}

/// A compact time chart: 2pt lines, recessive axes, one y-scale, and a hover
/// crosshair with a tooltip listing every series at that moment.
struct Sparkline: View {
    let points: [SparkPoint]
    /// Series name → color, in legend order.
    let series: [(name: String, color: Color)]
    var yDomain: ClosedRange<Double>?
    var height: CGFloat = 64
    let format: (Double) -> String

    @State private var hovered: Date?

    var body: some View {
        Chart {
            ForEach(points) { p in
                if series.count == 1 {
                    AreaMark(x: .value("Time", p.date), y: .value("Value", p.value))
                        .foregroundStyle(LinearGradient(colors: [color(of: p.series).opacity(0.22), color(of: p.series).opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", p.date), y: .value("Value", p.value), series: .value("Series", p.series))
                    .foregroundStyle(color(of: p.series))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let hovered, let snap = nearest(to: hovered) {
                RuleMark(x: .value("Time", snap.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(for: snap.date)
                    }
                ForEach(snap.values, id: \.series) { v in
                    PointMark(x: .value("Time", snap.date), y: .value("Value", v.value))
                        .foregroundStyle(color(of: v.series))
                        .symbolSize(40)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.2))
            }
        }
        .chartYScale(domain: yDomain ?? 0...max(1, (points.map(\.value).max() ?? 1) * 1.15))
        .chartLegend(.hidden)
        .chartXSelection(value: $hovered)
        .frame(height: height)
        .accessibilityLabel(accessibilitySummary)
    }

    private func color(of name: String) -> Color {
        series.first { $0.name == name }?.color ?? .accentColor
    }

    private func nearest(to date: Date) -> (date: Date, values: [(series: String, value: Double)])? {
        guard let closest = points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return nil }
        let values = series.compactMap { s in
            points.first { $0.series == s.name && $0.date == closest.date }.map { (series: s.name, value: $0.value) }
        }
        return (closest.date, values)
    }

    private func tooltip(for date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(series, id: \.name) { s in
                if let v = points.first(where: { $0.series == s.name && $0.date == date }) {
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        Text(series.count > 1 ? "\(s.name) \(format(v.value))" : format(v.value))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.inset))
    }

    private var accessibilitySummary: String {
        series.map { s in
            let latest = points.last { $0.series == s.name }?.value
            return "\(s.name): \(latest.map(format) ?? "no data")"
        }.joined(separator: ", ")
    }
}

/// A horizontal bar split into labelled segments with 2pt gaps (memory breakdown).
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let name: String
        let value: Double
        let color: Color
        var id: String { name }
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let usable = max(0, geo.size.width - gap * CGFloat(segments.count))
            HStack(spacing: gap) {
                ForEach(segments) { s in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(s.color)
                        .frame(width: total > 0 ? usable * CGFloat(s.value / total) : 0)
                        .help("\(s.name): \(Format.bytes(UInt64(s.value)))")
                }
                RoundedRectangle(cornerRadius: 3).fill(Viz.track)
            }
        }
        .frame(height: height)
    }
}

/// A single capacity bar (disk, battery).
struct CapacityBar: View {
    let fraction: Double
    var color: Color = Viz.sequential
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Viz.track)
                RoundedRectangle(cornerRadius: 3).fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}
