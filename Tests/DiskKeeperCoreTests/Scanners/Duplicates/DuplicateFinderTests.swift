import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class DuplicateFinderTests: XCTestCase {
    func testOnlyTrueCopiesCounted() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 1, count: DupFix.mb)
        let a = try DupFix.write(fx.abs("docs/a"), content)
        let copy = try DupFix.write(fx.abs("docs/a-copy"), content)
        let clone = fx.abs("docs/a-clone")
        try DupFix.clone(a, clone)
        let link = fx.abs("docs/a-link")
        XCTAssertEqual(Darwin.link(a, link), 0)
        let b = try DupFix.write(fx.abs("docs/b"), DupFix.data(seed: 2, count: DupFix.mb))
        let dataless = try DupFix.write(fx.abs("docs/c-dataless"), content)
        try DupFix.setBirthTime(a, Date(timeIntervalSinceNow: -5000))
        try DupFix.setBirthTime(copy, Date(timeIntervalSinceNow: -4000))
        try DupFix.setBirthTime(clone, Date(timeIntervalSinceNow: -3000))

        var options = DupFix.options(fx)
        options._datalessOverride = { $0 == dataless }
        let report = try await DupFix.find(fx, options: options)

        XCTAssertEqual(report.groups.count, 1)
        let g = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(Set(DupFix.paths(g)), [a, copy, clone])
        XCTAssertEqual(g.keeper.path, a)
        XCTAssertEqual(g.keeper.otherLinkPaths, [link])
        XCTAssertFalse(DupFix.paths(g).contains(b))
        XCTAssertFalse(DupFix.paths(g).contains(dataless))
        XCTAssertFalse(DupFix.paths(g).contains(link))
        XCTAssertEqual(report.stats.skippedDataless, 1)
        let cloneMember = try XCTUnwrap(g.members.first { $0.path == clone })
        XCTAssertTrue(cloneMember.sharesStorage)
        XCTAssertLessThanOrEqual(cloneMember.reclaimableBytes ?? .max, 16_384)
        let copyMember = try XCTUnwrap(g.members.first { $0.path == copy })
        XCTAssertFalse(copyMember.sharesStorage)
        XCTAssertLessThanOrEqual(abs(g.reclaimableBytes - copyMember.allocatedBytes), 16_384)
        XCTAssertEqual(g.id, "dup:\(g.digest.prefix(32)):\(DupFix.mb)")
        XCTAssertEqual(g.digest, DupFix.hex(content))
    }

    func testSameHeadTailDifferentMiddleSplitByFullHash() async throws {
        let fx = try FixtureHome()
        let base = DupFix.data(seed: 3, count: 3_000_000)
        var changed = base
        changed[1_500_000] ^= 0xFF
        try DupFix.write(fx.abs("a"), base)
        try DupFix.write(fx.abs("b"), changed)
        let report = try await DupFix.find(fx)
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.stats.partialHashed, 2)
        XCTAssertEqual(report.stats.fullHashed, 2)
        // a third, true copy of `a` forms a group of two and leaves `b` out
        try DupFix.write(fx.abs("c"), base)
        let report2 = try await DupFix.find(fx)
        XCTAssertEqual(report2.groups.count, 1)
        XCTAssertEqual(Set(DupFix.paths(report2.groups[0])), [fx.abs("a"), fx.abs("c")])
    }

    func testKeeperRules() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 4, count: DupFix.mb)
        let old = try DupFix.write(fx.abs("deep/er/old.bin"), content)
        let mid = try DupFix.write(fx.abs("mid.bin"), content)
        let inRepo = try DupFix.write(fx.abs("repo/src/new.bin"), content)
        try FileManager.default.createDirectory(atPath: fx.abs("repo/.git"), withIntermediateDirectories: true)
        try DupFix.setBirthTime(old, Date(timeIntervalSinceNow: -9000))
        try DupFix.setBirthTime(mid, Date(timeIntervalSinceNow: -5000))
        try DupFix.setBirthTime(inRepo, Date(timeIntervalSinceNow: -1000))
        let tree = try await IndexTest.index(fx)

        func order(_ rule: KeeperRule) async throws -> [String] {
            var o = DupFix.options(fx)
            o.keeperRule = rule
            o._cloneProbe = { _ in .unknown }
            let report = try await DuplicateFinder(options: o).find(in: tree)
            return DupFix.paths(try XCTUnwrap(report.groups.first))
        }
        let oldest = try await order(.oldest)
        XCTAssertEqual(oldest, [old, mid, inRepo])
        let git = try await order(.insideGitRepo)
        XCTAssertEqual(git.first, inRepo)
        XCTAssertEqual(Array(git.dropFirst()), [old, mid])
        let short = try await order(.shortestPath)
        XCTAssertEqual(short.first, mid)
        XCTAssertEqual(Array(short.dropFirst()), [old, inRepo].sorted { a, b in
            let ca = a.split(separator: "/").count, cb = b.split(separator: "/").count
            return ca != cb ? ca < cb : (a == old) })
    }

    func testKeeperTieBreaksByShortestPathThenName() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 5, count: DupFix.mb)
        let when = Date(timeIntervalSinceNow: -7000)
        let long = try DupFix.write(fx.abs("a-much-longer-name.bin"), content)
        let shortB = try DupFix.write(fx.abs("b.bin"), content)
        let shortA = try DupFix.write(fx.abs("a.bin"), content)
        for p in [long, shortB, shortA] { try DupFix.setBirthTime(p, when) }
        var o = DupFix.options(fx)
        o._cloneProbe = { _ in .unknown }
        let report = try await DuplicateFinder(options: o).find(in: try await IndexTest.index(fx))
        XCTAssertEqual(DupFix.paths(report.groups[0]), [shortA, shortB, long])
    }

    func testScopeExclusions() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 6, count: DupFix.mb)
        let a = try DupFix.write(fx.abs("docs/a"), content)
        let b = try DupFix.write(fx.abs("docs/b"), content)
        for rel in ["Library/Caches/x", ".cache/x", "proj/node_modules/pkg/y", "Pics.photoslibrary/z",
                    "Foo.app/Contents/z", "proj/.git/obj", "DerivedData/q"] {
            try DupFix.write(fx.abs(rel), content)
        }
        let report = try await DupFix.find(fx)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(Set(DupFix.paths(report.groups[0])), [a, b])
    }

    func testBelowMinimumAndEmptyFilesAreNeverCandidates() async throws {
        let fx = try FixtureHome()
        let small = DupFix.data(seed: 7, count: 900_000)
        try DupFix.write(fx.abs("s1"), small); try DupFix.write(fx.abs("s2"), small)
        try DupFix.write(fx.abs("e1"), Data()); try DupFix.write(fx.abs("e2"), Data())
        let report = try await DupFix.find(fx)
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.stats.candidates, 0)
    }

    func testAllFullClonesGroupDropped() async throws {
        let fx = try FixtureHome()
        let a = try DupFix.write(fx.abs("a"), DupFix.data(seed: 8, count: DupFix.mb))
        try DupFix.clone(a, fx.abs("a-clone-1"))
        try DupFix.clone(a, fx.abs("a-clone-2"))
        let report = try await DupFix.find(fx)
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.stats.groupsDroppedAllShared, 1)
    }

    func testUnknownCloneInfoStaysActionableButShared() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 9, count: DupFix.mb)
        try DupFix.write(fx.abs("a"), content); try DupFix.write(fx.abs("b"), content)
        var o = DupFix.options(fx)
        o._cloneProbe = { _ in .unknown }
        let g = try await DupFix.find(fx, options: o).groups[0]
        XCTAssertTrue(g.members.allSatisfy { $0.sharesStorage && !$0.sharesAllStorage && $0.reclaimableBytes == nil })
        XCTAssertEqual(g.reclaimableBytes, 0, "unknown bytes are never counted as certain")
    }

    func testChangedAfterIndexIsSkipped() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 10, count: DupFix.mb)
        let a = try DupFix.write(fx.abs("a"), content)
        try DupFix.write(fx.abs("b"), content)
        let tree = try await IndexTest.index(fx)
        try DupFix.write(a, content + Data([1]))        // resized after the index
        let report = try await DuplicateFinder(options: DupFix.options(fx)).find(in: tree)
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.stats.skippedChanged, 1)
    }

    func testHashDoesNotModifyFixture() async throws {
        let fx = try FixtureHome()
        let content = DupFix.data(seed: 11, count: DupFix.mb)
        try DupFix.write(fx.abs("a"), content); try DupFix.write(fx.abs("b"), content)
        let tree = try await IndexTest.index(fx)
        let before = try fx.snapshot()
        _ = try await DuplicateFinder(options: DupFix.options(fx)).find(in: tree)
        XCTAssertEqual(try fx.snapshot(), before)
    }
}
