import XCTest
@testable import DiskKeeperCore

final class SimctlDeviceListTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/simctl-unavailable.json")
        return try Data(contentsOf: url)
    }

    func testParsesRecordedFixtureAndSkipsRecordsWithoutUDID() throws {
        let devices = try SimctlDeviceList.parse(try fixture())
        XCTAssertEqual(devices.map(\.udid), ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"])
        XCTAssertEqual(devices.filter { !$0.isAvailable }.map(\.name), ["iPhone 15"])
        XCTAssertEqual(devices[0].runtimeShortName, "iOS 17.5")
        XCTAssertTrue(devices[1].isBooted)
        XCTAssertFalse(devices[0].isBooted)
    }

    func testBadDocumentsThrowInsteadOfCrashing() {
        XCTAssertThrowsError(try SimctlDeviceList.parse(Data("nope".utf8)))
        XCTAssertThrowsError(try SimctlDeviceList.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try SimctlDeviceList.parse(Data("[]".utf8)))
        XCTAssertEqual(try SimctlDeviceList.parse(Data(#"{"devices":{}}"#.utf8)), [])
        XCTAssertEqual(try SimctlDeviceList.parse(Data(#"{"devices":{"r":"x"}}"#.utf8)), [])
    }

    func testRuntimeShortNameFallsBack() {
        let d = SimctlDevice(udid: "u", name: "n", runtimeID: "weird", isAvailable: false, dataPath: nil, state: nil)
        XCTAssertEqual(d.runtimeShortName, "weird")
    }
}
