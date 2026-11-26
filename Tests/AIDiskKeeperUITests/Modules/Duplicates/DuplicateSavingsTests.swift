import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class DuplicateSavingsTests: XCTestCase {
    private func mixed() -> DuplicateGroup {
        DupUI.group("e", [
            DupUI.member("/h/keep", inode: 1),
            DupUI.member("/h/real", inode: 2, bytes: 1_000_000),
            DupUI.member("/h/fullClone", inode: 3, all: true),
            DupUI.member("/h/partial", inode: 4, reclaimable: 16_384, shares: true),
            DupUI.member("/h/hardlink", inode: 5, links: ["/h/other"]).withShares(),
            DupUI.member("/h/unknown", inode: 6, reclaimable: nil),
        ])
    }

    func testSavingsAreTrueCopiesOnly() {
        let g = mixed()
        XCTAssertEqual(g.reclaimableBytes, 1_000_000, "header = Core's number: only the real copy")
        var s = DuplicateSelection()
        for m in g.members { s.toggle(m.path, in: g, actionable: !m.sharesAllStorage) }
        XCTAssertEqual(s.savings.certainBytes, 1_000_000)
        XCTAssertTrue(s.savings.mayFreeLess)
        XCTAssertEqual(s.count, 4)
    }

    func testRealCopyAloneIsCertain() {
        let g = mixed()
        var s = DuplicateSelection()
        s.toggle("/h/real", in: g, actionable: true)
        XCTAssertEqual(s.savings, DuplicateSavings(certainBytes: 1_000_000, mayFreeLess: false))
    }

    func testSharedAndUnknownCountZeroAndFlagIt() {
        let g = mixed()
        for path in ["/h/partial", "/h/hardlink", "/h/unknown"] {
            var s = DuplicateSelection()
            s.toggle(path, in: g, actionable: true)
            XCTAssertEqual(s.savings, DuplicateSavings(certainBytes: 0, mayFreeLess: true), path)
        }
    }

    func testSavingsAcrossGroupsAreIncremental() {
        let a = DupUI.plain("f", count: 3), b = DupUI.plain("g", count: 2, bytes: 5_000_000)
        var s = DuplicateSelection()
        s.toggle(a.members[1].path, in: a, actionable: true)
        s.toggle(a.members[2].path, in: a, actionable: true)
        s.toggle(b.members[1].path, in: b, actionable: true)
        XCTAssertEqual(s.savings.certainBytes, 2_000_000 + 5_000_000)
        s.removeGroup(a.id)
        XCTAssertEqual(s.savings.certainBytes, 5_000_000)
    }
}

private extension DuplicateMember {
    func withShares() -> DuplicateMember {
        DuplicateMember(path: path, device: device, inode: inode, otherLinkPaths: otherLinkPaths, logicalBytes: logicalBytes,
                        allocatedBytes: allocatedBytes, reclaimableBytes: reclaimableBytes, sharesStorage: true,
                        sharesAllStorage: false, created: created, modified: modified, isInGitRepo: isInGitRepo)
    }
}
