import XCTest
@testable import DiskKeeperCore

final class DiskKeeperCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(DiskKeeperCore.version.isEmpty)
    }
}
