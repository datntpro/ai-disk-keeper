import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class LargeOldFiltersTests: XCTestCase {
    private func names(_ f: LargeOldFilters) -> [String] {
        f.apply(LargeOldFix.sample, now: LargeOldFix.now).map { ($0.path as NSString).lastPathComponent }.sorted()
    }

    func testDefaultIs500MBAndSixMonths() {
        let f = LargeOldFilters()
        XCTAssertEqual(f.minBytes, .mb500)
        XCTAssertEqual(f.age, .m6)
        XCTAssertNil(f.folder)
        XCTAssertTrue(f.kinds.isEmpty)
        XCTAssertEqual(names(f), ["Archive-2024.zip", "Docker.dmg", "Xcode_16.2.xip", "demo.mov", "linked.bin"])
    }

    func testSize() {
        var f = LargeOldFilters(); f.minBytes = .gb1
        XCTAssertEqual(names(f), ["Archive-2024.zip", "Xcode_16.2.xip", "demo.mov"])
        f.minBytes = .gb5
        XCTAssertEqual(names(f), ["Archive-2024.zip"])
        f.minBytes = .mb100; f.age = .any
        XCTAssertEqual(names(f).count, 7)
    }

    func testAge() {
        var f = LargeOldFilters(); f.minBytes = .mb100
        f.age = .y1
        XCTAssertEqual(names(f), ["Archive-2024.zip", "demo.mov", "small.bin"])
        f.age = .m1
        XCTAssertEqual(names(f).count, 6)   // everything except nothing newer than a month
        f.age = .any
        XCTAssertEqual(names(f).count, 7)
    }

    func testFolderKindAndSearch() {
        var f = LargeOldFilters(); f.minBytes = .mb100; f.age = .any
        f.folder = LargeOldFix.root + "/Downloads"
        XCTAssertEqual(names(f), ["Docker.dmg", "Xcode_16.2.xip"])
        f.folder = LargeOldFix.root + "/Down"   // a prefix of a name is not a folder
        XCTAssertTrue(names(f).isEmpty)
        f.folder = nil
        f.kinds = [.video]
        XCTAssertEqual(names(f), ["demo.mov", "recent.mov"])
        f.kinds = []
        f.search = "xcode"
        XCTAssertEqual(names(f), ["Xcode_16.2.xip"])
        f.search = "movies/"
        XCTAssertEqual(names(f), ["demo.mov", "recent.mov"])
    }

    func testKindFreeIgnoresKindsOnly() {
        var f = LargeOldFilters(); f.kinds = [.video]
        let free = f.kindFree(LargeOldFix.sample, now: LargeOldFix.now)
        XCTAssertEqual(free.count, 5)
        XCTAssertTrue(free.contains { $0.kind == .archive })
        f.age = .any
        XCTAssertEqual(f.kindFree(LargeOldFix.sample, now: LargeOldFix.now).count, 6)   // size still applies
    }
}
