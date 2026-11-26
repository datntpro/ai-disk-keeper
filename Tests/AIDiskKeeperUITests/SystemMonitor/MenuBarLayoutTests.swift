import AppKit
import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class MenuBarLayoutTests: XCTestCase {
    private func entries(_ metrics: [MetricID], upSmall: Bool = false) -> [MenuBarLayout.Entry] {
        metrics.map { m in
            switch m {
            case .disk: .init(metric: .disk, text: "182 GB")
            case .network: .init(metric: .network, text: "↓1.2M", up: "↑24K", upIsNegligible: upSmall)
            default: .init(metric: m, text: "12%")
            }
        }
    }

    private func subsets() -> [[MetricID]] {
        let all = MetricID.defaultOrder
        return (0..<(1 << all.count)).map { mask in all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element) }
    }

    func testEveryStyleAndSubsetStaysWithinTheBudget() {
        for style in MenuBarStyle.allCases {
            for subset in subsets() {
                let r = MenuBarLayout.layout(style: style, entries: entries(subset), measure: MenuBarLayout.measureText)
                XCTAssertLessThanOrEqual(r.width, MenuBarLayout.budget, "\(style) \(subset)")
                XCTAssertGreaterThanOrEqual(r.width, MenuBarLayout.glyphWidth)
            }
        }
    }

    func testNothingInTheBarIsTheT47Glyph() {
        let r = MenuBarLayout.layout(style: .readout, entries: [], measure: MenuBarLayout.measureText)
        XCTAssertEqual(r.mode, .glyph)
        XCTAssertEqual(r.width, 18)
        XCTAssertEqual(r.stepDown, 0)
        let free = MenuBarLayout.layout(style: .ridge, entries: entries([.disk]), measure: MenuBarLayout.measureText)
        XCTAssertEqual(free.mode, .glyph, "disk alone is the T47 free-space text")
        XCTAssertEqual(free.cells.count, 2)
        let glyphStyle = MenuBarLayout.layout(style: .glyph, entries: entries([.cpu, .memory]), measure: MenuBarLayout.measureText)
        XCTAssertEqual(glyphStyle.mode, .glyph)
    }

    func testStepDownOrder() {
        let all = entries(MetricID.defaultOrder, upSmall: true)
        let readout = MenuBarLayout.layout(style: .readout, entries: all, measure: MenuBarLayout.measureText)
        XCTAssertGreaterThan(readout.stepDown, 0, "four metrics don't fit as chosen")
        // a roomy measure keeps step 0 with separators
        let narrow = MenuBarLayout.layout(style: .readout, entries: entries([.cpu]), measure: { _ in 20 })
        XCTAssertEqual(narrow.stepDown, 0)
        // a huge measure falls through to Live strata
        let huge = MenuBarLayout.layout(style: .readout, entries: all, measure: { _ in 500 })
        XCTAssertEqual(huge.mode, .strata)
        XCTAssertEqual(huge.stepDown, 3)
        XCTAssertEqual(MenuBarLayout.layout(style: .liveStrata, entries: entries([.cpu]), measure: MenuBarLayout.measureText).mode, .strata)
    }

    func testStepOneDropsSeparatorsAndNegligibleUpload() {
        var found = false
        for measureWidth in stride(from: 10.0, to: 60.0, by: 2.0) {
            let r = MenuBarLayout.layout(style: .readout, entries: entries([.cpu, .memory, .network], upSmall: true), measure: { CGFloat($0.count) * CGFloat(measureWidth) / 10 })
            if r.stepDown == 1 {
                found = true
                XCTAssertFalse(r.cells.contains { $0.kind == .separator })
                XCTAssertFalse(r.cells.last?.text?.contains("↑") ?? true)
            }
        }
        XCTAssertTrue(found)
    }

    func testFreeSpaceCellFitsTheRealFormatterOutputInEveryUnitAndLanguage() {
        var values: [Int64] = [0, 1, 999, 1_000]
        var base: Int64 = 1_000
        while base <= 1_000_000_000_000 {
            for m in [1, 9, 10, 12, 31, 99, 123, 312, 999, 1_023, 9_999] { values.append(base * Int64(m) + base / 3) }
            base *= 1000
        }
        values.append(31_070_000_000)
        let width = MenuBarLayout.reservedDiskWidth(MenuBarLayout.measureText)
        for id in ["en", "vi"] {
            for v in values {
                let text = Formatting.bytes(v, locale: Locale(identifier: id))
                XCTAssertLessThanOrEqual(MenuBarLayout.measureText(text), width, "\(id) \(v) -> \(text)")
            }
        }
        let r = MenuBarLayout.layout(style: .glyph, entries: [.init(metric: .disk, text: Formatting.bytes(31_070_000_000, locale: Locale(identifier: "en")))], measure: MenuBarLayout.measureText)
        XCTAssertGreaterThanOrEqual(r.cells.last?.width ?? 0, MenuBarLayout.measureText("31.07 GB"))
    }

    func testReservedWidthsAreTheSameInEnglishAndVietnamese() {
        var widths: [CGFloat] = []
        for language in [AppLanguage.en, .vi] {
            L10n.apply(language)
            defer { L10n.apply(.en) }
            let e = [MenuBarLayout.Entry(metric: .cpu, text: language == .vi ? "9%" : "12%"),
                     MenuBarLayout.Entry(metric: .network, text: "↓" + MonitorFormatting.compactRate(1_200_000, units: .bytes), up: "↑24K")]
            widths.append(MenuBarLayout.layout(style: .readout, entries: e, measure: MenuBarLayout.measureText).width)
        }
        XCTAssertEqual(widths[0], widths[1])
    }

    func testPreviewMatchesTheLabelLayoutForWorstCaseText() {
        var s = AppSettings.defaults
        s.setMetric(.cpu, inMenuBar: true)
        s.setMetric(.network, inMenuBar: true)
        let preview = MenuBarLayout.preview(s)
        let label = MenuBarLayout.layout(style: s.menuBarStyle, entries: MenuBarLayout.previewEntries(s), measure: MenuBarLayout.measureText)
        XCTAssertEqual(preview, label)
    }

    func testRateFormatting() {
        XCTAssertEqual(MonitorFormatting.compactRate(1_200_000, units: .bytes, locale: Locale(identifier: "en")), "1.2M")
        XCTAssertEqual(MonitorFormatting.compactRate(1_200_000, units: .bytes, locale: Locale(identifier: "vi")), "1,2M")
        XCTAssertEqual(MonitorFormatting.compactRate(24_000, units: .bytes, locale: Locale(identifier: "en")), "24K")
        XCTAssertEqual(MonitorFormatting.compactRate(0, units: .bytes), "0K")
        XCTAssertEqual(MonitorFormatting.rate(1_200_000, units: .bytes, locale: Locale(identifier: "en")), "1.2 MB/s")
        XCTAssertEqual(MonitorFormatting.rate(125_000, units: .bits, locale: Locale(identifier: "en")), "1.0 Mb/s")
        XCTAssertEqual(MonitorFormatting.percent(0.123), "12%")
        XCTAssertEqual(MonitorFormatting.percent(1.4), "100%")
    }
}

@MainActor
final class MenuBarF5Tests: XCTestCase {
    func testSeparatorKeepsAtLeastTwoPointsClearOfAFull100Percent() {
        let e: [MenuBarLayout.Entry] = [.init(metric: .cpu, text: "100%"), .init(metric: .memory, text: "100%")]
        // a roomy measure keeps step 0 (separators); the real font gives the real "100%" width
        let r = MenuBarLayout.layout(style: .readout, entries: e, measure: { _ in MenuBarLayout.measureText("100%") })
        XCTAssertEqual(r.stepDown, 0)
        var x: CGFloat = 0
        var textRight: CGFloat?
        for cell in r.cells {
            if cell.kind == .separator, let right = textRight {
                let ink = x + MenuBarLayout.separatorPadding
                XCTAssertGreaterThanOrEqual(ink - right, 2)
                // and the other side
                textRight = nil
                x += cell.width + MenuBarLayout.spacing
                continue
            }
            if case .metric = cell.kind {
                let text = MenuBarLayout.measureText("100%")
                textRight = x + cell.width
                XCTAssertEqual(cell.width, MenuBarLayout.markWidth + MenuBarLayout.spacing + text)
            }
            x += cell.width + MenuBarLayout.spacing
        }
        let drawn = x - MenuBarLayout.spacing
        XCTAssertEqual(drawn, r.width, accuracy: 0.001)
        // The 100% label renders without crashing and has the layout's width.
        let img = MenuBarLabelRenderer.render(LabelContent(layout: r))
        XCTAssertEqual(img.size.width, r.width, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(MenuBarLayout.separatorCellWidth, MenuBarLayout.separatorWidth + 4)
    }

    func testLayoutNamesFollowTheStepDown() {
        func r(_ step: Int) -> MenuBarLayout.Result { .init(mode: .readout, cells: [], width: 0, stepDown: step) }
        XCTAssertEqual([0, 1, 2, 3].map { MenuBarLayout.layoutName(r($0)) }, [.full, .compact, .ridgeNoValues, .liveStrata])
        XCTAssertEqual(SystemMonitorCopy.layoutName(.ridgeNoValues), "Ridge (no values)")
        XCTAssertEqual(SystemMonitorCopy.layoutName(.liveStrata), "Live strata")
        XCTAssertTrue(SystemMonitorCopy.layoutLineWhy("Compact").contains("too many metrics for the bar width"))
    }

    func testFreeSpaceUsesTheMenuBarFont() {
        XCTAssertEqual(MenuBarLayout.diskFont.pointSize, NSFont.menuBarFont(ofSize: 0).pointSize)
        XCTAssertEqual(MenuBarLayout.measureDiskText("182 GB"),
                       ceil(("182 GB" as NSString).size(withAttributes: [.font: NSFont.menuBarFont(ofSize: 0)]).width))
    }

    func testTopToolsCaption() {
        XCTAssertEqual(MenuBarCopy.topToolsNote, "AI tool data only. Caches, worktrees and build files are counted separately.")
    }
}
