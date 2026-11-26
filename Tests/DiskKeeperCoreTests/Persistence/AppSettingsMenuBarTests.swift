import XCTest
@testable import DiskKeeperCore

final class AppSettingsMenuBarTests: XCTestCase {
    func testDefaults() {
        let s = AppSettings.defaults
        XCTAssertTrue(s.showMenuBarItem)
        XCTAssertFalse(s.menuBarShowsFreeSpace)
        XCTAssertTrue(s.lowSpaceAlertEnabled)
        XCTAssertEqual(s.lowSpaceThresholdPercent, 10)
    }

    func testRoundTripKeepsTheFourFields() throws {
        var s = AppSettings.defaults
        s.showMenuBarItem = false
        s.menuBarShowsFreeSpace = true
        s.lowSpaceAlertEnabled = false
        s.setLowSpaceThreshold(percent: 15)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertFalse(back.showMenuBarItem)
        XCTAssertTrue(back.menuBarShowsFreeSpace)
        XCTAssertFalse(back.lowSpaceAlertEnabled)
        XCTAssertEqual(back.lowSpaceThresholdPercent, 15)
        XCTAssertEqual(back.schemaVersion, 1)
    }

    func testOldFileWithoutTheFieldsDecodesToDefaults() throws {
        let old = #"{"schemaVersion":1,"hasCompletedOnboarding":true,"projectRoots":["~"],"excludedPaths":[],"disabledTools":[],"language":"vi"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertTrue(s.hasCompletedOnboarding)
        XCTAssertTrue(s.showMenuBarItem)
        XCTAssertFalse(s.menuBarShowsFreeSpace)
        XCTAssertTrue(s.lowSpaceAlertEnabled)
        XCTAssertEqual(s.lowSpaceThresholdPercent, 10)
    }

    func testThresholdIsClamped() throws {
        var s = AppSettings.defaults
        s.setLowSpaceThreshold(percent: 0)
        XCTAssertEqual(s.lowSpaceThresholdPercent, 1)
        s.setLowSpaceThreshold(percent: 99)
        XCTAssertEqual(s.lowSpaceThresholdPercent, 50)
        let wild = #"{"lowSpaceThresholdPercent":-5}"#
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(wild.utf8)).lowSpaceThresholdPercent, 1)
    }
}
