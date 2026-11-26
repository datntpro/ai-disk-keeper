import XCTest
@testable import DiskKeeperCore

final class SimctlDeviceListTests: XCTestCase {
    /// A sanitized recording of `simctl list devices unavailable --json` (inline: SwiftPM warns on stray resource files).
    private func fixture() throws -> Data { Data(Self.recorded.utf8) }

    private static let recorded = """
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-17-5" : [
      {
        "dataPath" : "/Users/example/Library/Developer/CoreSimulator/Devices/11111111-1111-4111-8111-111111111111/data",
        "dataPathSize" : 1048576,
        "logPath" : "/Users/example/Library/Logs/CoreSimulator/11111111-1111-4111-8111-111111111111",
        "udid" : "11111111-1111-4111-8111-111111111111",
        "isAvailable" : false,
        "availabilityError" : "runtime profile not found",
        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
        "state" : "Shutdown",
        "name" : "iPhone 15"
      },
      {
        "dataPath" : "/Users/example/Library/Developer/CoreSimulator/Devices/22222222-2222-4222-8222-222222222222/data",
        "udid" : "22222222-2222-4222-8222-222222222222",
        "isAvailable" : true,
        "state" : "Booted",
        "name" : "iPhone 15 Pro"
      },
      { "name" : "no udid here" }
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-10-0" : []
  }
}
"""

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
