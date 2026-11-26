import AppKit
import DiskKeeperCore
import Foundation

/// The menu bar item's width budget and step-down rules. Pure: the label and the Settings width preview call the
/// same function, so they can't disagree.
enum MenuBarLayout {
    static let budget: CGFloat = 140
    static let glyphWidth: CGFloat = 18
    static let markWidth: CGFloat = 10
    static let ridgeWidth: CGFloat = 24
    static let spacing: CGFloat = 3
    static let separatorWidth: CGFloat = 1

    /// The widest string each cell can show, so digits never move the item.
    static let reservedDisk = "999 GB"
    static let reservedPercent = "100%"
    static let reservedNetwork = "↓999K ↑999K"
    static let reservedNetworkDownOnly = "↓999K"

    /// One metric's current text. `networkDown`/`networkUp` replace `text` for the network.
    struct Entry: Equatable {
        var metric: MetricID
        var text: String
        var up: String?
        /// Network upload under 1 KB/s: the step-down may drop the ↑ half.
        var upIsNegligible = false
    }

    enum Mode: Equatable { case glyph, readout, ridge, strata }

    struct Cell: Equatable {
        enum Kind: Equatable { case glyph, separator, metric(MetricID) }
        var kind: Kind
        var text: String?
        var showsMark = false
        var showsRidge = false
        var width: CGFloat
    }

    struct Result: Equatable {
        var mode: Mode
        var cells: [Cell]
        var width: CGFloat
        /// 0 = as chosen … 3 = Live strata.
        var stepDown: Int
        var fits: Bool { width <= MenuBarLayout.budget }
    }

    static func layout(style: MenuBarStyle, entries: [Entry], measure: (String) -> CGFloat) -> Result {
        let nonDisk = entries.filter { $0.metric != .disk }
        let disk = entries.first { $0.metric == .disk }
        if style == .glyph || nonDisk.isEmpty {
            // Exactly the T47 item: glyph, plus the free-space text when it is on.
            var cells = [Cell(kind: .glyph, width: glyphWidth)]
            if disk != nil { cells.append(Cell(kind: .metric(.disk), text: disk?.text, width: measure(reservedDisk))) }
            return Result(mode: .glyph, cells: cells, width: total(cells, gap: 4), stepDown: 0)
        }
        let start = style == .liveStrata ? 3 : 0
        for step in start...3 {
            let r = build(style: style, step: step, entries: entries, measure: measure)
            if r.fits || step == 3 { return r }
        }
        return build(style: style, step: 3, entries: entries, measure: measure)
    }

    private static func build(style: MenuBarStyle, step: Int, entries: [Entry], measure: (String) -> CGFloat) -> Result {
        if step >= 3 {
            let cells = [Cell(kind: .glyph, width: glyphWidth)]
            return Result(mode: .strata, cells: cells, width: glyphWidth, stepDown: 3)
        }
        let ridge = style == .ridge || step == 2
        let values = step < 2
        let separators = step == 0
        let downOnly = step >= 1
        var cells = [Cell(kind: .glyph, width: glyphWidth)]
        var first = true
        for e in entries {
            if separators, !first { cells.append(Cell(kind: .separator, width: separatorWidth)) }
            first = false
            switch e.metric {
            case .disk:
                cells.append(Cell(kind: .metric(.disk), text: e.text, width: measure(reservedDisk)))
            case .cpu, .memory:
                let w = ridge ? ridgeWidth + (values ? spacing + measure(reservedPercent) : 0)
                    : markWidth + spacing + measure(reservedPercent)
                cells.append(Cell(kind: .metric(e.metric), text: ridge && !values ? nil : e.text,
                                  showsMark: !ridge, showsRidge: ridge, width: w))
            case .network:
                let dropUp = downOnly && e.upIsNegligible
                let reserved = dropUp ? reservedNetworkDownOnly : reservedNetwork
                let text = dropUp ? e.text : (e.up.map { e.text + " " + $0 } ?? e.text)
                let w = ridge ? ridgeWidth + (values ? spacing + measure(reserved) : 0) : markWidth + spacing + measure(reserved)
                cells.append(Cell(kind: .metric(.network), text: ridge && !values ? nil : text,
                                  showsMark: !ridge, showsRidge: ridge, width: w))
            }
        }
        return Result(mode: ridge ? .ridge : .readout, cells: cells, width: total(cells, gap: spacing), stepDown: step)
    }

    private static func total(_ cells: [Cell], gap: CGFloat) -> CGFloat {
        cells.reduce(0) { $0 + $1.width } + gap * CGFloat(max(cells.count - 1, 0))
    }

    // MARK: Measuring

    static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }

    /// Width of a string in the bar font, rounded up to a whole point.
    static func measureText(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Worst-case entries for the Settings width preview (reserved strings, so it never changes with live values).
    static func previewEntries(_ s: AppSettings) -> [Entry] {
        s.menuBarMetricsInOrder.map { m in
            switch m {
            case .disk: Entry(metric: .disk, text: reservedDisk)
            case .network: Entry(metric: .network, text: "↓999K", up: "↑999K")
            default: Entry(metric: m, text: reservedPercent)
            }
        }
    }

    static func preview(_ s: AppSettings) -> Result {
        layout(style: s.menuBarStyle, entries: previewEntries(s), measure: measureText)
    }
}
