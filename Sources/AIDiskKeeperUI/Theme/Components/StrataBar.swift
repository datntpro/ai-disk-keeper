import Charts
import SwiftUI

/// The signature "strata" bar: disk usage by layer in one rounded bar, with optional hatched free space.
struct StrataBar: View {
    let segments: [StrataSegment]
    let total: Int64
    var free: Int64?
    var height: CGFloat = 34

    @Environment(\.adkIncreasedContrast) private var increasedContrast

    private var model: StrataBarModel { StrataBarModel(segments: segments, total: total, free: free) }

    var body: some View {
        let m = model
        Chart {
            ForEach(m.bars) { bar in
                BarMark(xStart: .value(Text(verbatim: "start"), Double(bar.start)), xEnd: .value(Text(verbatim: "end"), Double(bar.end)),
                        y: .value(Text(verbatim: "row"), "disk"), height: .ratio(1))
                    .foregroundStyle(bar.segment.layer.color)
                    .accessibilityLabel(bar.segment.label)
            }
            ForEach(m.bars.dropLast()) { bar in
                RuleMark(x: .value(Text(verbatim: "edge"), Double(bar.end)))
                    .foregroundStyle(.adkSurface)
                    .lineStyle(StrokeStyle(lineWidth: ADKTheme.hairline))
            }
        }
        .chartXScale(domain: 0...Double(max(m.total, 1)))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.background(.adkSunken) }
        .overlay(alignment: .trailing) {
            if m.free > 0 {
                Canvas { ctx, size in
                    HatchPattern.draw(in: ctx, rect: CGRect(origin: .zero, size: size), color: .adkLine)
                }
                .containerRelativeFrame(.horizontal) { w, _ in w * m.fraction(m.free) }
                .accessibilityHidden(true)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(increasedContrast ? .adkLineStrong : .adkLine, lineWidth: ADKTheme.hairline)
        }
        .strataAnimation(m.bars.map(\.end))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc("strata.bar.a11y", "Disk usage: \(Self.summary(m, top: 3))"))
        .accessibilityChartDescriptor(StrataBarDescriptor(model: m))
    }

    /// "Label, size, N percent" for the largest `top` layers.
    static func summary(_ m: StrataBarModel, top: Int) -> String {
        m.bars.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(top).map { bar in
            let bytes = bar.end - bar.start
            return loc("strata.bar.segment", "\(bar.segment.label), \(Formatting.bytes(bytes)), \(Formatting.count(m.percent(bytes))) percent")
        }.joined(separator: "; ")
    }
}

/// Audio Graphs: every segment as a data point.
struct StrataBarDescriptor: AXChartDescriptorRepresentable {
    let model: StrataBarModel

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = model.bars.map { Double($0.end - $0.start) }
        let points = model.bars.map { AXDataPoint(x: $0.segment.label, y: Double($0.end - $0.start)) }
        let maxY = max(values.max() ?? 1, 1)
        let x = AXCategoricalDataAxisDescriptor(title: loc("strata.bar.axisLayer", "Layer"), categoryOrder: model.bars.map(\.segment.label))
        let y = AXNumericDataAxisDescriptor(title: loc("strata.bar.axisSize", "Size"), range: 0...maxY, gridlinePositions: []) {
            Formatting.bytes(Int64($0))
        }
        return AXChartDescriptor(title: loc("strata.bar.title", "Disk usage"), summary: nil, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [AXDataSeriesDescriptor(name: loc("strata.bar.title", "Disk usage"), isContinuous: false, dataPoints: points)])
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}
