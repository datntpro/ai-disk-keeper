import XCTest
@testable import DiskKeeperCore

final class DiskIndexerReadOnlyTests: XCTestCase {
    func testIndexDoesNotModifyFixture() async throws {
        let fx = try FixtureHome()
        for i in 0..<20 { try fx.file("d/f\(i).txt", bytes: 500) }
        try fx.file("d/big.bin", bytes: 3 << 20)
        try fx.file(".ssh/id_rsa", bytes: 100)
        try fx.symlink("d/link", to: "f0.txt")
        let before = try fx.snapshot()
        _ = try await IndexTest.index(fx)
        let after = try fx.snapshot()
        XCTAssertEqual(before, after)
    }
}
