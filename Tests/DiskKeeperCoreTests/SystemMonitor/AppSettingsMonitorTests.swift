import XCTest
@testable import DiskKeeperCore

final class AppSettingsMonitorTests: XCTestCase {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testT47EraFileGetsDefaultsAndUnchangedBar() throws {
        let s = try decode(#"{"schemaVersion":1,"hasCompletedOnboarding":true,"showMenuBarItem":true,"menuBarShowsFreeSpace":true}"#)
        XCTAssertEqual(s.monitorOrder, [.disk, .cpu, .memory, .network])
        XCTAssertTrue(s.monitorDisabled.isEmpty)
        XCTAssertTrue(s.menuBarMetrics.isEmpty)
        XCTAssertEqual(s.menuBarStyle, .readout)
        XCTAssertEqual(s.menuBarRefreshSeconds, 5)
        XCTAssertEqual(s.networkUnits, .bytes)
        XCTAssertFalse(s.popoverShowsTopProcesses)
        XCTAssertEqual(s.popoverHistoryMinutes, 1)
        XCTAssertEqual(s.menuBarMetricsInOrder, [.disk], "only the T47 free-space text is in the bar")
        XCTAssertEqual(AppSettings.defaults.menuBarMetricsInOrder, [])
    }

    func testLenientDecode() throws {
        let s = try decode(#"{"monitorOrder":["network","bogus","network","cpu"],"monitorDisabled":["disk","cpu","x"],"menuBarMetrics":["disk","memory","y"],"menuBarStyle":"neon","menuBarRefreshSeconds":7,"networkUnits":"nibbles","popoverHistoryMinutes":9}"#)
        XCTAssertEqual(s.monitorOrder, [.network, .cpu, .disk, .memory])
        XCTAssertEqual(s.monitorDisabled, [.cpu], "disk can't be disabled")
        XCTAssertEqual(s.menuBarMetrics, [.memory])
        XCTAssertEqual(s.menuBarStyle, .readout)
        XCTAssertEqual(s.menuBarRefreshSeconds, 5)
        XCTAssertEqual(s.networkUnits, .bytes)
        XCTAssertEqual(s.popoverHistoryMinutes, 5)
    }

    func testEditingAndRoundTrip() throws {
        var s = AppSettings.defaults
        s.setMetric(.disk, monitored: false)
        XCTAssertTrue(s.isMonitored(.disk))
        s.setMetric(.cpu, inMenuBar: true)
        s.setMetric(.memory, monitored: false)
        s.setMetric(.memory, inMenuBar: true)
        XCTAssertEqual(s.menuBarMetricsInOrder, [.cpu], "a disabled metric never shows in the bar")
        s.moveMetric(.disk, by: -1)   // edge: no-op
        s.moveMetric(.network, by: 1)
        XCTAssertEqual(s.monitorOrder, [.disk, .cpu, .memory, .network])
        s.moveMetric(.network, by: -1)
        XCTAssertEqual(s.monitorOrder, [.disk, .cpu, .network, .memory])
        s.menuBarStyle = .ridge
        s.networkUnits = .bits
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
