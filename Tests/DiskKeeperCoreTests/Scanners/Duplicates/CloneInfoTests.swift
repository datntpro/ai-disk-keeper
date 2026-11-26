import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class CloneInfoTests: XCTestCase {
    private func known(_ i: CloneInfo, file: StaticString = #filePath, line: UInt = #line)
        throws -> (id: UInt64, refs: UInt32, priv: Int64, all: Bool) {
        guard case .known(let id, let refs, let priv, let all, _) = i else {
            throw XCTSkip("volume does not report clone attributes", file: file, line: line)
        }
        return (id, refs, priv, all)
    }

    func testCloneSharesEverything() throws {
        let tmp = try TemporaryDirectory()
        let a = try DupFix.write(tmp.path("a"), DupFix.data(seed: 1, count: 2 << 20))
        let b = tmp.path("b")
        try DupFix.clone(a, b)
        let ia = try known(CloneInfo.probe(a)), ib = try known(CloneInfo.probe(b))
        XCTAssertEqual(ia.id, ib.id)
        XCTAssertEqual(ia.refs, 2); XCTAssertEqual(ib.refs, 2)
        XCTAssertEqual(ia.priv, 0); XCTAssertEqual(ib.priv, 0)
        XCTAssertTrue(ia.all); XCTAssertTrue(ib.all)
    }

    func testWritingToACloneMakesItPartial() throws {
        let tmp = try TemporaryDirectory()
        let a = try DupFix.write(tmp.path("a"), DupFix.data(seed: 1, count: 2 << 20))
        let b = tmp.path("b")
        try DupFix.clone(a, b)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: b))
        try h.write(contentsOf: Data([1, 2]))
        try h.close()
        let ia = try known(CloneInfo.probe(a)), ib = try known(CloneInfo.probe(b))
        XCTAssertNotEqual(ia.id, ib.id)
        XCTAssertFalse(ia.all); XCTAssertFalse(ib.all)
        XCTAssertGreaterThan(ib.priv, 0)
        XCTAssertLessThan(ib.priv, 2 << 20)
    }

    func testRealCopyOwnsItsBlocks() throws {
        let tmp = try TemporaryDirectory()
        let d = DupFix.data(seed: 1, count: 2 << 20)
        let a = try DupFix.write(tmp.path("a"), d), c = try DupFix.write(tmp.path("c"), d)
        let ic = try known(CloneInfo.probe(c))
        XCTAssertEqual(ic.refs, 1)
        XCTAssertFalse(ic.all)
        var st = stat(); lstat(c, &st)
        XCTAssertEqual(ic.priv, Int64(st.st_blocks) * 512)
        _ = a
    }

    func testMissingFileIsUnknown() {
        XCTAssertEqual(CloneInfo.probe("/nonexistent/adk-\(UUID().uuidString)"), .unknown)
    }

    func testVolumeCapabilityQueryDoesNotCrash() throws {
        let tmp = try TemporaryDirectory()
        // APFS tracks clones; other volumes may not. Only the call itself is asserted on.
        _ = CloneProbe.volumeTracksClones(tmp.url.path)
        XCTAssertFalse(CloneProbe.volumeTracksClones("/nonexistent/adk-\(UUID().uuidString)"))
    }
}
