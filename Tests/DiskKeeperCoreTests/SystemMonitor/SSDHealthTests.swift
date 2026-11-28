import XCTest
@testable import DiskKeeperCore

final class SSDHealthTests: XCTestCase {
    /// Recorded from an M1 Pro (APPLE SSD AP0512R) on 2026-11-27; the rest of the 512-byte page is zero.
    private static let fixture: [UInt8] = {
        let head: [UInt8] = [
        0x00, 0x2d, 0x01, 0x64, 0x63, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xb8, 0xe3, 0xb1, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xda, 0xf2, 0xd4, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xc0, 0x28, 0xf4, 0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x87, 0x6d, 0xa4, 0x4e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x3b, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xea, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        return head + [UInt8](repeating: 0, count: 512 - head.count)
    }()

    func testParsesRecordedPage() throws {
        let h = try XCTUnwrap(SSDHealth(page: Self.fixture))
        XCTAssertEqual(h.criticalWarning, 0)
        XCTAssertEqual(h.temperatureCelsius, 28)
        XCTAssertEqual(h.availableSparePercent, 100)
        XCTAssertEqual(h.spareThresholdPercent, 99)
        XCTAssertEqual(h.percentageUsed, 1)
        XCTAssertEqual(h.bytesWritten, 81_064_666 * 512_000)
        XCTAssertEqual(h.bytesRead, 78_767_032 * 512_000)
        XCTAssertEqual(h.powerCycles, 315)
        XCTAssertEqual(h.powerOnHours, 1002)
        XCTAssertEqual(h.unsafeShutdowns, 27)
        XCTAssertEqual(h.mediaErrors, 0)
        XCTAssertFalse(h.needsAttention)
        XCTAssertFalse(h.bytesWrittenSaturated)
    }

    func testZeroOrAbsurdTemperatureIsUnknown() throws {
        var page = Self.fixture
        page[1] = 0; page[2] = 0
        XCTAssertNil(try XCTUnwrap(SSDHealth(page: page)).temperatureCelsius)
        page[1] = 0xff; page[2] = 0xff
        XCTAssertNil(try XCTUnwrap(SSDHealth(page: page)).temperatureCelsius)
        page[1] = 0x2e; page[2] = 0x01  // 302 K = 28.85 °C
        XCTAssertEqual(try XCTUnwrap(SSDHealth(page: page)).temperatureCelsius, 29)
    }

    func testWrongSizeIsRejected() {
        XCTAssertNil(SSDHealth(page: Array(Self.fixture.prefix(511))))
        XCTAssertNil(SSDHealth(page: []))
    }

    func testCounterAboveSixtyFourBitsSaturates() throws {
        var page = Self.fixture
        page[48 + 8] = 1  // high half of DATA_UNITS_WRITTEN
        let h = try XCTUnwrap(SSDHealth(page: page))
        XCTAssertEqual(h.bytesWritten, .max)
        XCTAssertTrue(h.bytesWrittenSaturated)
    }

    func testUnitsTimesBlockSizeOverflowSaturates() throws {
        var page = Self.fixture
        for i in 0..<8 { page[48 + i] = 0xff }
        XCTAssertEqual(try XCTUnwrap(SSDHealth(page: page)).bytesWritten, .max)
    }

    func testAttentionRules() throws {
        var page = Self.fixture
        page[5] = 80
        XCTAssertTrue(try XCTUnwrap(SSDHealth(page: page)).needsAttention, "wear 80 %")
        page[5] = 79
        XCTAssertFalse(try XCTUnwrap(SSDHealth(page: page)).needsAttention)
        page[0] = 0x04
        XCTAssertTrue(try XCTUnwrap(SSDHealth(page: page)).needsAttention, "critical warning")
        page[0] = 0; page[3] = 50
        XCTAssertTrue(try XCTUnwrap(SSDHealth(page: page)).needsAttention, "spare below threshold")
    }

    /// Real hardware only; skipped on CI and in the VM (virtual disk).
    func testLiveReadOnRealHardware() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ADK_HW_TESTS"] == "1", "set ADK_HW_TESTS=1 on a real Mac")
        let h = try XCTUnwrap(LiveSSDHealthReader().read())
        XCTAssertTrue((0...200).contains(h.percentageUsed))
        XCTAssertTrue((0...100).contains(h.availableSparePercent))
    }
}
