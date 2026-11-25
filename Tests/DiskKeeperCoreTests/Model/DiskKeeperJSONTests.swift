import XCTest
@testable import DiskKeeperCore

final class DiskKeeperJSONTests: XCTestCase {
    func testDatesAreISO8601UTCWithFractionalSeconds() throws {
        let s = try jsonString(Date(timeIntervalSince1970: 1_793_000_000.5))
        XCTAssertNotNil(s.range(of: #"^"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"$"#, options: .regularExpression), s)
    }

    func testDecodesDatesWithoutFractionalSeconds() throws {
        let d = try decodeJSON(Date.self, "\"2026-11-01T10:00:00Z\"")
        XCTAssertEqual(d.timeIntervalSince1970, 1_793_527_200, accuracy: 0.001)
    }

    func testMillisecondPrecisionRoundTrip() throws {
        let original = Date(timeIntervalSince1970: 1_793_000_000.123)
        XCTAssertLessThan(abs(try roundTrip(original).timeIntervalSince(original)), 0.001)
    }

    func testKeysAreSorted() throws {
        let s = try jsonString(["b": 1, "a": 2, "c": 3])
        XCTAssertEqual(s, #"{"a":2,"b":1,"c":3}"#)
    }
}
