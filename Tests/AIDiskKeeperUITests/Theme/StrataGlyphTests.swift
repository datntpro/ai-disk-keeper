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
        let topRows = 0...(Int(18 * 2) / 2 - 1) // top half at 2×
        let counts = try [-1.0, 0, 0.25, 0.5, 1, 2].map { try inkCount(StrataGlyph.gaugeImage(freeFraction: $0), rows: topRows) }
        XCTAssertEqual(counts[0], counts[1])
        XCTAssertEqual(counts[4], counts[5])
        for i in 1..<5 { XCTAssertLessThan(counts[i - 1] , counts[i] + 1) }
        XCTAssertLessThan(counts[1], counts[3])
        XCTAssertLessThan(counts[3], counts[4])
    }

    func testGeometryMatchesMarkJSON() throws {
        struct Layer: Decodable { let height: Double }
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
    }
}
