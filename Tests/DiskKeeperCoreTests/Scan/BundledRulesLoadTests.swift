import XCTest
@testable import DiskKeeperCore

/// Protect patterns are a global union, so one file's `protect` can make another file's `self` path a
/// container and reject it. This catches that cross-file interference; every rules PR must keep it green.
final class BundledRulesLoadTests: XCTestCase {
    func testAllBundledRulesLoadWithoutErrors() throws {
        let fixture = try FixtureHome()
        let result = RuleHarness.loadAllBundled(fixture: fixture)
        XCTAssertEqual(result.errors, [], "\(result.errors.map(\.description).joined(separator: "\n"))")
    }
}
