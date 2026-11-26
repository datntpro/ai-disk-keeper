import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class DuplicateSelectionTests: XCTestCase {
    func testSelectingEveryMemberLeavesTheKeeperUnselected() {
        for n in [2, 3, 5] {
            let g = DupUI.plain("a", count: n)
            var s = DuplicateSelection()
            for m in g.members { s.toggle(m.path, in: g, actionable: true) }
            XCTAssertFalse(s.isSelected(g.keeper.path, in: g.id), "n=\(n)")
            XCTAssertEqual(s.count, n - 1)
            XCTAssertFalse(s.canSelect(g.keeper.path, in: g, actionable: true))
        }
    }

    func testReportOnlyMembersCannotBeSelected() {
        let g = DupUI.group("b", [DupUI.member("/h/a", inode: 1), DupUI.member("/h/b", inode: 2, all: true),
                                  DupUI.member("/h/c", inode: 3)])
        var s = DuplicateSelection()
        XCTAssertFalse(s.toggle("/h/b", in: g, actionable: false))
        XCTAssertTrue(s.toggle("/h/c", in: g, actionable: true))
        XCTAssertEqual(s.selectedPaths(in: g.id), ["/h/c"])
        XCTAssertFalse(s.canSelect("/not/a/member", in: g, actionable: true))
    }

    func testKeeperChangeDropsTheNewKeeperFromTheSelection() {
        let g = DupUI.plain("c", count: 3)
        var s = DuplicateSelection()
        for m in g.members.dropFirst() { s.toggle(m.path, in: g, actionable: true) }
        let newKeeper = g.members[1].path
        let moved = g.reordered(keeper: newKeeper)!
        s.groupChanged(moved)
        XCTAssertFalse(s.isSelected(newKeeper, in: g.id))
        XCTAssertEqual(s.selectedPaths(in: g.id), [g.members[2].path])
    }

    func testFirstAndLastTogglesBalanceTheSavingsToZero() {
        let g = DupUI.plain("d", count: 3)
        var s = DuplicateSelection()
        s.toggle(g.members[1].path, in: g, actionable: true)
        XCTAssertEqual(s.savings.certainBytes, 1_000_000)
        s.toggle(g.members[1].path, in: g, actionable: true)
        XCTAssertEqual(s.savings, .zero)
        XCTAssertTrue(s.isEmpty)
    }

    /// 1 000 random sequences of toggle / keep-instead / rule change over random groups.
    func testRandomSequencesNeverBreakKeepOne() {
        var rng = SeededGenerator(seed: 0xD00F)
        for _ in 0..<1000 {
            var groups: [DuplicateGroup] = []
            var inode: UInt64 = 1
            for gi in 0..<Int.random(in: 1...4, using: &rng) {
                let n = Int.random(in: 2...6, using: &rng)
                let members = (0..<n).map { i -> DuplicateMember in
                    defer { inode += 1 }
                    let kind = Int.random(in: 0..<5, using: &rng)
                    return DupUI.member("/Users/tester/g\(gi)/\(String(repeating: "x", count: Int.random(in: 1...6, using: &rng)))\(i)",
                                        inode: inode, reclaimable: kind == 4 ? nil : -1, shares: kind == 3, all: kind == 2,
                                        git: Bool.random(using: &rng), created: Double(Int.random(in: 1...50, using: &rng)))
                }
                // Keep the group valid for the finder's invariant: not all non-keepers full clones.
                groups.append(DupUI.group("\(gi)\(gi)", members))
            }
            var s = DuplicateSelection()
            for _ in 0..<40 {
                let gi = Int.random(in: 0..<groups.count, using: &rng)
                switch Int.random(in: 0..<4, using: &rng) {
                case 0, 1:
                    let m = groups[gi].members.randomElement(using: &rng)!
                    s.toggle(m.path, in: groups[gi], actionable: !m.sharesAllStorage)
                case 2:
                    let m = groups[gi].members.randomElement(using: &rng)!
                    groups[gi] = groups[gi].reordered(keeper: m.path)!
                    s.groupChanged(groups[gi])
                default:
                    let rule = KeeperRule.allCases.randomElement(using: &rng)!
                    for i in groups.indices { groups[i] = groups[i].reordered(by: rule); s.groupChanged(groups[i]) }
                }
                for g in groups {
                    let sel = s.selectedPaths(in: g.id)
                    XCTAssertFalse(sel.contains(g.keeper.path))
                    XCTAssertTrue(g.members.contains { !sel.contains($0.path) }, "a member must stay unselected")
                    for m in g.members where m.sharesAllStorage { XCTAssertFalse(sel.contains(m.path)) }
                }
            }
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
