import Accessibility
import DiskKeeperCore
import SwiftUI

/// Line + soft fill from a ring buffer's samples, plotted by time (so 5 s and 2 s samples mix). A gap longer than
/// `gap` seconds breaks the line. Fixed height; plain `Path`, no per-point views.
struct Sparkline: View {
    let samples: [MetricHistory.Sample]
    let now: Double
    let window: Double
    /// Fixed y-max (1 for fractions); nil auto-scales to the window's peak with `floor`.
    var yMax: Double? = 1
    var floor: Double = 0
    var gap: Double = 20
    var color: Color = .adkAccent
    var height: CGFloat = 28
    @Environment(\.adkIncreasedContrast) private var highContrast

    var body: some View {
        let highContrast = highContrast
        return Canvas { ctx, size in
            guard samples.count > 1 else {
                var base = Path()
                base.move(to: CGPoint(x: 0, y: size.height - 1))
                base.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                ctx.stroke(base, with: .color(.adkLineStrong), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                return
            }
            let top = max(yMax ?? max(samples.map(\.value).max() ?? 0, floor), floor, 0.000_001)
            func point(_ s: MetricHistory.Sample) -> CGPoint {
                CGPoint(x: size.width * (1 - CGFloat((now - s.time) / window)),
                        y: size.height - size.height * CGFloat(min(s.value / top, 1)))
            }
            var line = Path(), fill = Path()
            var previous: MetricHistory.Sample?
            for s in samples {
                let p = point(s)
                if let prev = previous, s.time - prev.time <= gap {
                    line.addLine(to: p); fill.addLine(to: p)
                } else {
                    if previous != nil { fill.addLine(to: CGPoint(x: point(previous!).x, y: size.height)); fill.closeSubpath() }
                    line.move(to: p)
                    fill.move(to: CGPoint(x: p.x, y: size.height)); fill.addLine(to: p)
                }
                previous = s
            }
            if let last = previous { fill.addLine(to: CGPoint(x: point(last).x, y: size.height)); fill.closeSubpath() }
            ctx.fill(fill, with: .color(color.opacity(highContrast ? 0.35 : 0.18)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: highContrast ? 2 : 1.4, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Audio Graph support: the same series as a chart descriptor.
struct SeriesChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let samples: [MetricHistory.Sample]
    let now: Double
    let format: (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let ages = samples.map { now - $0.time }
        let values = samples.map(\.value)
        let x = AXNumericDataAxisDescriptor(title: SystemMonitorCopy.chartSeconds, range: 0...max(ages.max() ?? 1, 1),
                                            gridlinePositions: []) { String(Int($0.rounded())) }
        let y = AXNumericDataAxisDescriptor(title: title, range: 0...max(values.max() ?? 1, 0.000_001),
                                            gridlinePositions: []) { format($0) }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: true,
                                            dataPoints: zip(ages, values).map { AXDataPoint(x: $0, y: $1) })
        return AXChartDescriptor(title: title, summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}

/// Download below the centre line, upload above it; both share one auto scale with a 100 KB/s floor.
struct NetworkMirrorChart: View {
    let down: [MetricHistory.Sample]
    let up: [MetricHistory.Sample]
    let now: Double
    let window: Double
    var height: CGFloat = 40
    @Environment(\.adkIncreasedContrast) private var highContrast

    var body: some View {
        let highContrast = highContrast
        return Canvas { ctx, size in
            let mid = size.height / 2
            var base = Path()
            base.move(to: CGPoint(x: 0, y: mid)); base.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(base, with: .color(.adkLine), lineWidth: 1)
            let peak = max(100_000, down.map(\.value).max() ?? 0, up.map(\.value).max() ?? 0)
            func area(_ s: [MetricHistory.Sample], direction: CGFloat, color: Color) {
                guard s.count > 1 else { return }
                var p = Path()
                p.move(to: CGPoint(x: size.width * (1 - CGFloat((now - s[0].time) / window)), y: mid))
                for v in s {
                    p.addLine(to: CGPoint(x: size.width * (1 - CGFloat((now - v.time) / window)),
                                          y: mid + direction * mid * CGFloat(min(v.value / peak, 1))))
                }
                p.addLine(to: CGPoint(x: size.width * (1 - CGFloat((now - s[s.count - 1].time) / window)), y: mid))
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(highContrast ? 0.9 : 0.6)))
            }
            area(down, direction: 1, color: StrataLayer.docker.color)
            area(up, direction: -1, color: StrataLayer.ai.color)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One small bar per logical core; performance cores in the accent colour, efficiency cores in the media tone.
struct CoreStrip: View {
    let cores: [Double]
    let performanceCount: Int?

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                let isP = performanceCount.map { i < $0 } ?? true
                RoundedRectangle(cornerRadius: 1.5)
                    .fill((isP ? Color.adkAccent : StrataLayer.media.color).opacity(0.35 + 0.65 * min(max(v, 0), 1)))
                    .frame(height: max(3, 14 * CGFloat(min(max(v, 0), 1))))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// App / Wired / Compressed over the total, then free.
struct MemoryStrataBar: View {
    let reading: MemoryReading

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(reading.totalBytes), 1)
            HStack(spacing: 1) {
                seg(Double(reading.appBytes) / total, .adkKeep, geo.size.width)
                seg(Double(reading.wiredBytes) / total, StrataLayer.apps.color, geo.size.width)
                seg(Double(reading.compressedBytes) / total, StrataLayer.docker.color, geo.size.width)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.adkSunken, in: RoundedRectangle(cornerRadius: 3))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func seg(_ f: Double, _ c: Color, _ w: CGFloat) -> some View {
        c.frame(width: max(0, w * CGFloat(min(f, 1))))
    }
}
