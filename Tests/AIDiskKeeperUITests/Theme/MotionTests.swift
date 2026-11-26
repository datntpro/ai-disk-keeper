import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class MotionTests: XCTestCase {
    func testReduceMotionRemovesAnimation() {
        XCTAssertNil(StrataMotion.animation(reduceMotion: true))
        XCTAssertNotNil(StrataMotion.animation(reduceMotion: false))
    }

    func testProgressCurve() {
        XCTAssertEqual(StrataMotion.progress(0), 0)
        XCTAssertEqual(StrataMotion.progress(1), 1)
        XCTAssertEqual(StrataMotion.progress(-1), 0)
        XCTAssertEqual(StrataMotion.progress(2), 1)
        var last = 0.0
        for i in 0...100 {
            let v = StrataMotion.progress(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, last - 1e-9, "not monotonic at \(i)")
            XCTAssertTrue((0...1).contains(v))
            last = v
        }
        // cubic-bezier(.2,.8,.2,1) is front-loaded.
        XCTAssertGreaterThan(StrataMotion.progress(0.25), 0.5)
    }

    func testStrataAnimationModifierRenders() {
        // `accessibilityReduceMotion` is read-only, so the Reduce Motion branch is covered by `animation(reduceMotion:)`.
        let r = ImageRenderer(content: Text(verbatim: "x").strataAnimation(1))
        XCTAssertNotNil(r.cgImage)
    }
}
