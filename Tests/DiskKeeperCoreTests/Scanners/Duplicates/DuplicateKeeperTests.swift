import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class DuplicateKeeperTests: XCTestCase {
    private func fixtureGroup(_ fx: FixtureHome, rule: KeeperRule = .oldest) async throws -> (DuplicateReport, [String]) {
        let content = DupFix.data(seed: 40, count: DupFix.mb)
        let old = try DupFix.write(fx.abs("deep/er/old.bin"), content)
        let mid = try DupFix.write(fx.abs("mid.bin"), content)
        let inRepo = try DupFix.write(fx.abs("repo/src/new.bin"), content)
        try FileManager.default.createDirectory(atPath: fx.abs("repo/.git"), withIntermediateDirectories: true)
        try DupFix.setBirthTime(old, Date(timeIntervalSinceNow: -9000))
        try DupFix.setBirthTime(mid, Date(timeIntervalSinceNow: -5000))
        try DupFix.setBirthTime(inRepo, Date(timeIntervalSinceNow: -1000))
        var o = DupFix.options(fx)
        o.keeperRule = rule
        o._cloneProbe = { _ in .unknown }
        let report = try await DuplicateFinder(options: o).find(in: try await IndexTest.index(fx))
        return (report, [old, mid, inRepo])
    }

    func testReorderedByRuleEqualsTheFindersOwnOrder() async throws {
        let fx = try FixtureHome()
        let (base, _) = try await fixtureGroup(fx, rule: .oldest)
        let group = try XCTUnwrap(base.groups.first)
        for rule in KeeperRule.allCases {
            let (fresh, _) = try await {
                var o = DupFix.options(fx)
                o.keeperRule = rule
                o._cloneProbe = { _ in .unknown }
                let r = try await DuplicateFinder(options: o).find(in: try await IndexTest.index(fx))
                return (r, 0)
            }()
            let expected = try XCTUnwrap(fresh.groups.first)
            let reordered = group.reordered(by: rule)
            XCTAssertEqual(DupFix.paths(reordered), DupFix.paths(expected), "\(rule)")
            XCTAssertEqual(reordered.id, group.id)
            XCTAssertEqual(reordered.digest, group.digest)
            XCTAssertEqual(reordered.partialDigest, group.partialDigest)
            XCTAssertEqual(reordered.logicalBytes, group.logicalBytes)
        }
    }

    func testReorderedFromAnyStartingOrderIsTheSame() async throws {
        let fx = try FixtureHome()
        let (base, _) = try await fixtureGroup(fx)
        let group = try XCTUnwrap(base.groups.first)
        let shuffled = DuplicateGroup(digest: group.digest, partialDigest: group.partialDigest,
                                      logicalBytes: group.logicalBytes, members: group.members.reversed())
        for rule in KeeperRule.allCases {
            XCTAssertEqual(DupFix.paths(shuffled.reordered(by: rule)), DupFix.paths(group.reordered(by: rule)))
        }
    }

    func testManualKeeperMovesThatMemberFirst() async throws {
        let fx = try FixtureHome()
        let (base, paths) = try await fixtureGroup(fx)
        let group = try XCTUnwrap(base.groups.first)
        XCTAssertEqual(group.keeper.path, paths[0])
        let moved = try XCTUnwrap(group.reordered(keeper: paths[2]))
        XCTAssertEqual(moved.keeper.path, paths[2])
        XCTAssertEqual(Set(DupFix.paths(moved)), Set(DupFix.paths(group)))
        XCTAssertEqual(moved.id, group.id)
        XCTAssertEqual(try XCTUnwrap(group.reordered(keeper: paths[0])), group)
        XCTAssertNil(group.reordered(keeper: "/not/a/member"))
    }

    func testReclaimableFollowsTheNewKeeper() {
        func member(_ path: String, inode: UInt64, reclaimable: Int64?, shared: Bool = false) -> DuplicateMember {
            DuplicateMember(path: path, device: 1, inode: inode, otherLinkPaths: [], logicalBytes: 100,
                            allocatedBytes: 100, reclaimableBytes: reclaimable, sharesStorage: shared,
                            sharesAllStorage: false, created: Date(timeIntervalSince1970: Double(inode) * 1000),
                            modified: .distantPast, isInGitRepo: false)
        }
        let g = DuplicateGroup(digest: String(repeating: "b", count: 64), partialDigest: "p", logicalBytes: 100, members: [
            member("/h/a", inode: 1, reclaimable: 100), member("/h/b", inode: 2, reclaimable: 60),
            member("/h/c", inode: 3, reclaimable: 100, shared: true),
        ])
        XCTAssertEqual(g.reclaimableBytes, 60)
        XCTAssertEqual(g.reordered(keeper: "/h/b")?.reclaimableBytes, 100)
    }

    func testItemsForReportDropGuardedAndTinyGroups() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 41, count: DupFix.mb)
        try DupFix.write(fx.abs("docs/a"), content)
        try DupFix.write(fx.abs("docs/b"), content)
        try DupFix.write(fx.abs("docs/c"), content)
        let other = DupFix.data(seed: 42, count: 2_000_000)
        try DupFix.write(fx.abs("more/x"), other)
        try DupFix.write(fx.abs("more/y"), other)
        var o = DupFix.options(fx)
        o._cloneProbe = { _ in .unknown }
        let report = try await DuplicateFinder(options: o).find(in: try await IndexTest.index(fx))
        XCTAssertEqual(report.groups.count, 2)

        let open = try ScanGuard(environment: fx.env, protectPatterns: [])
        let all = DuplicateScanner.items(for: report, rule: .oldest, pathGuard: open, userID: getuid())
        XCTAssertEqual(all.count, 2)
        for group in report.groups {
            let items = try XCTUnwrap(all[group.id])
            XCTAssertEqual(items.count, group.members.count)
            XCTAssertEqual(items.filter { $0.flags.contains(.suggestedKeeper) }.map(\.path), [group.keeper.path])
            XCTAssertTrue(items.allSatisfy { $0.groupID == group.id })
        }

        // One of "docs" guarded: the group keeps two. One of "more" guarded: that group is dropped whole.
        let guarded = try ScanGuard(environment: fx.env, protectPatterns: [
            ProtectedPaths.escapeGlob(fx.abs("docs/b")), ProtectedPaths.escapeGlob(fx.abs("more/y"))])
        let some = DuplicateScanner.items(for: report, rule: .oldest, pathGuard: guarded, userID: getuid())
        XCTAssertEqual(some.count, 1)
        let docs = try XCTUnwrap(some.values.first)
        XCTAssertEqual(docs.count, 2)
        XCTAssertFalse(docs.contains { $0.path == fx.abs("docs/b") })

        // Foreign-owned members (a different uid) are dropped, so nothing is left.
        let foreign = DuplicateScanner.items(for: report, rule: .oldest, pathGuard: open, userID: getuid() &+ 1)
        XCTAssertTrue(foreign.isEmpty)
    }

    func testReorderedItemsMoveTheKeeperFlag() async throws {
        let fx = try FixtureHome()
        let (base, paths) = try await fixtureGroup(fx)
        let group = try XCTUnwrap(base.groups.first).reordered(keeper: paths[1])!
        let report = DuplicateReport(groups: [group], stats: DuplicateStats(), warnings: [])
        let items = try XCTUnwrap(DuplicateScanner.items(
            for: report, rule: .oldest, pathGuard: try ScanGuard(environment: fx.env, protectPatterns: []),
            userID: getuid())[group.id])
        XCTAssertEqual(items.filter { $0.flags.contains(.suggestedKeeper) }.map(\.path), [paths[1]])
    }
}
