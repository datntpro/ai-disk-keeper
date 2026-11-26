import AppKit
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

/// Samples the pixels AppKit actually draws (the token-pair test can't see `.borderedProminent` ignoring the label colour).
@MainActor
final class ProminentButtonRenderTests: XCTestCase {
    private func render(dark: Bool) -> NSBitmapImageRep? {
        let content = Button("Clean") {}
            .adkProminentButton()
            .controlSize(.large)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Draw into an sRGB-tagged bitmap so the sampled components are the token values (no device-profile shift).
        guard let blank = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let rep = blank.retagging(with: .sRGB) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func testRenderedLabelContrastMeetsAAInBothAppearances() throws {
        for dark in [false, true] {
            let rep = try XCTUnwrap(render(dark: dark))
            var counts: [RGBA: Int] = [:]
            var pixels: [RGBA] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { continue }
                    let p = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: 1)
                    counts[p, default: 0] += 1
                    pixels.append(p)
                }
            }
            // The button fill is the dominant opaque colour; the label is the pixel furthest from it in contrast.
            let (fill, fillCount) = try XCTUnwrap(counts.max { $0.value < $1.value })
            let appearance: ADKAppearance = dark ? .dark : .light
            let tokenFill = ADKColor.accent.rgba(appearance), tokenInk = ADKColor.onAccent.rgba(appearance)
            XCTAssertGreaterThan(fillCount, 500, "no solid fill drawn (dark=\(dark))")
            // Drawn values drift slightly from the tokens (display-profile conversion), so match with a tolerance.
            XCTAssertLessThan(distance(fill, tokenFill), 0.1, "fill is not the accent (dark=\(dark))")
            let ink = try XCTUnwrap(pixels.max { contrastRatio($0, fill) < contrastRatio($1, fill) })
            XCTAssertLessThan(distance(ink, tokenInk), 0.1, "label is not drawn in onAccent (dark=\(dark)): \(ink)")
            // Floor on the drawn pair (profile drift trims ~0.8 off the exact token ratio); the old system style measured 1.9.
            XCTAssertGreaterThanOrEqual(contrastRatio(ink, fill), 3.5, "drawn label vs fill (dark=\(dark))")
            XCTAssertGreaterThanOrEqual(contrastRatio(tokenInk, tokenFill), 4.5, "token pair (dark=\(dark))")
        }
    }

    private func distance(_ a: RGBA, _ b: RGBA) -> Double {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }
}
