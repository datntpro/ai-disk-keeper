import XCTest
@testable import AIDiskKeeperUI

final class LowSpaceMonitorTests: XCTestCase {
    private func fires(_ percents: [Double], threshold: Double = 0.10, from monitor: LowSpaceMonitor = LowSpaceMonitor()) -> [Bool] {
        var m = monitor
        return percents.map { m.observe(freeFraction: $0 / 100, threshold: threshold) }
    }

    func testOncePerCrossingWithHysteresis() {
        // 15 → 9 (fire) → 8 → 9.5 (no fire) → 12.5 (re-arm) → 9 (fire): exactly two.
        let out = fires([15, 9, 8, 9.5, 12.5, 9])
        XCTAssertEqual(out, [false, true, false, false, false, true])
        XCTAssertEqual(out.filter { $0 }.count, 2)
    }

    func testRisingToJustAboveThresholdDoesNotRearm() {
        XCTAssertEqual(fires([9, 10.5, 9]), [true, false, false])
    }

    func testBoundaryAtExactlyTheThresholdIsNotLow() {
        XCTAssertEqual(fires([10]), [false])
        XCTAssertEqual(fires([9.99]), [true])
    }

    func testPersistenceRoundTrip() throws {
        let name = "T47-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(LowSpaceMonitor.load(from: defaults).armed)   // default
        var m = LowSpaceMonitor()
        XCTAssertTrue(m.observe(freeFraction: 0.05, threshold: 0.10))
        m.save(to: defaults)
        var relaunched = LowSpaceMonitor.load(from: defaults)
        XCTAssertFalse(relaunched.armed)
        XCTAssertFalse(relaunched.observe(freeFraction: 0.05, threshold: 0.10), "a relaunch while still low must not alert again")
        XCTAssertFalse(relaunched.observe(freeFraction: 0.30, threshold: 0.10))
        XCTAssertTrue(relaunched.armed)
    }

    func testThresholdChangeReevaluatesWithoutFiring() {
        var m = LowSpaceMonitor()
        m.thresholdChanged(freeFraction: 0.12, threshold: 0.15)   // already below the new level: quiet
        XCTAssertFalse(m.armed)
        XCTAssertFalse(m.observe(freeFraction: 0.12, threshold: 0.15))
        m.thresholdChanged(freeFraction: 0.12, threshold: 0.05)   // lowered far below: armed again
        XCTAssertTrue(m.armed)
    }
}
