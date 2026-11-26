import AppKit
import XCTest
@testable import AIDiskKeeperUI

final class StrataGlyphTests: XCTestCase {
    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    private func inkCount(_ image: NSImage, rows: ClosedRange<Int>? = nil) throws -> Int {
        let rep = try bitmap(image)
        var n = 0
        for y in 0..<rep.pixelsHigh where rows?.contains(y) ?? true {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { n += 1 }
        }
        return n
    }

    func testTemplateAndSize() {
        let image = StrataGlyph.image()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testOnlyAlphaVaries() throws {
        let rep = try bitmap(StrataGlyph.image())
        var sawInk = false
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if c.alphaComponent > 0 {
                    sawInk = true
                    XCTAssertEqual(c.redComponent, 0, accuracy: 0.001)
                    XCTAssertEqual(c.greenComponent, 0, accuracy: 0.001)
                    XCTAssertEqual(c.blueComponent, 0, accuracy: 0.001)
                }
            }
        }
        XCTAssertTrue(sawInk)
    }

    func testGaugeClampsAndIsMonotonic() throws {
        // Top bar occupies the upper rows of the bitmap (row 0 is the top).
        // Rows of the top bar only (bitmap row 0 is the top edge): 18 pt − (bottom + 2 pitches + bar) … 18 pt − (bottom + 2 pitches).
        let top = 18 - (StrataGlyph.bottom + 2 * (StrataGlyph.barHeight + StrataGlyph.gap) + StrataGlyph.barHeight)
        let probe = try bitmap(StrataGlyph.image())
        let k = Double(probe.pixelsHigh) / 18
        let topRows = Int(top * k)...(Int((top + StrataGlyph.barHeight) * k) - 1)
        let counts = try [-1.0, 0, 0.25, 0.5, 1, 2].map { try inkCount(StrataGlyph.gaugeImage(freeFraction: $0), rows: topRows) }
        XCTAssertEqual(counts[0], counts[1])
        XCTAssertEqual(counts[4], counts[5])
        for i in 1..<5 { XCTAssertLessThanOrEqual(counts[i - 1], counts[i]) }
        XCTAssertLessThan(counts[1], counts[3])
        XCTAssertLessThan(counts[3], counts[4])
    }

    /// Every bar edge lands on a whole pixel at 1× and 2×: rows are fully opaque inside a bar and fully clear just outside.
    func testBarEdgesAreCrispAtOneAndTwoX() throws {
        for scale in [1, 2] {
            let px = 18 * scale
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            StrataGlyph.image().draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let x = Int((StrataGlyph.left + 6) * CGFloat(scale))
            func alpha(_ pt: CGFloat) -> CGFloat { // pt measured upward from the bottom edge
                rep.colorAt(x: x, y: px - 1 - Int(pt * CGFloat(scale)))?.alphaComponent ?? -1
            }
            for i in 0..<3 {
                let y0 = StrataGlyph.bottom + CGFloat(i) * (StrataGlyph.barHeight + StrataGlyph.gap)
                XCTAssertEqual(alpha(y0), 1, accuracy: 0.01, "bar \(i) bottom row @\(scale)x")
                XCTAssertEqual(alpha(y0 + StrataGlyph.barHeight - 1 / CGFloat(scale)), 1, accuracy: 0.01, "bar \(i) top row @\(scale)x")
                XCTAssertEqual(alpha(y0 - 1 / CGFloat(scale)), 0, accuracy: 0.01, "below bar \(i) @\(scale)x")
            }
        }
    }

    func testGeometryMatchesMarkJSON() throws {
        struct Layer: Decodable { let y, height: Double }
        struct Glyph: Decodable { let pointSize, barHeight, gap, radius, left, bottom, topBarWidth, barWidth: Double; let count: Int }
        struct Mark: Decodable { let small: [Layer]; let glyph: Glyph }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packaging/Icon/StrataMark.json")
        let mark = try JSONDecoder().decode(Mark.self, from: Data(contentsOf: url))
        XCTAssertEqual(mark.glyph.count, mark.small.count)
        XCTAssertEqual(StrataGlyph.barCount, mark.glyph.count)
        let g = mark.glyph
        XCTAssertEqual(StrataGlyph.basePointSize, g.pointSize, accuracy: 0.5)
        XCTAssertEqual(StrataGlyph.barHeight, g.barHeight, accuracy: 0.5)
        XCTAssertEqual(StrataGlyph.gap, g.gap, accuracy: 0.5)
        XCTAssertEqual(StrataGlyph.radius, g.radius, accuracy: 0.5)
        XCTAssertEqual(StrataGlyph.left, g.left, accuracy: 0.5)
        XCTAssertEqual(StrataGlyph.bottom, g.bottom, accuracy: 0.5)
        XCTAssertEqual(StrataGlyph.topBarWidth, g.topBarWidth, accuracy: 0.5)
        XCTAssertEqual(StrataGlyph.barWidth, g.barWidth, accuracy: 0.5)
        // Proportions of the small (≤ 32 px) icon variant, scaled to the glyph's point size.
        let pt = g.pointSize
        let sm = mark.small
        let pitch = (sm[1].y - sm[0].y) * pt, bar = sm[0].height * pt
        let span = (sm[sm.count - 1].y + sm[sm.count - 1].height - sm[0].y) * pt
        let glyphPitch = Double(StrataGlyph.barHeight + StrataGlyph.gap)
        XCTAssertEqual(glyphPitch, pitch, accuracy: 0.5, "layer pitch")
        XCTAssertEqual(Double(StrataGlyph.barHeight), bar, accuracy: 0.5, "layer height")
        XCTAssertEqual(Double(StrataGlyph.barCount - 1) * glyphPitch + Double(StrataGlyph.barHeight), span, accuracy: 0.5, "stack span")
    }
}
