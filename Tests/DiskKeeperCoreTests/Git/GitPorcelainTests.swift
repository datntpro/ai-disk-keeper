import XCTest

@testable import DiskKeeperCore

final class GitPorcelainTests: XCTestCase {
    private func nul(_ fields: [String]) -> Data { Data((fields.joined(separator: "\0") + "\0").utf8) }

    func testParsesWorktreeListZ() {
        let data = nul([
            "worktree /repo", "HEAD aaa", "branch refs/heads/main", "",
            "worktree /wt1", "HEAD bbb", "detached", "locked agent busy", "",
            "worktree /gone", "HEAD ccc", "branch refs/heads/x", "prunable gitdir file points to non-existent location", "",
            "worktree /bare", "bare", "",
        ])
        let e = GitPorcelain.parseWorktreeList(data)
        XCTAssertEqual(e.count, 4)
        XCTAssertTrue(e[0].isMain)
        XCTAssertEqual(e[0].branch, "refs/heads/main")
        XCTAssertTrue(e[1].isDetached)
        XCTAssertTrue(e[1].isLocked)
        XCTAssertEqual(e[1].lockReason, "agent busy")
        XCTAssertTrue(e[2].isPrunable)
        XCTAssertNotNil(e[2].prunableReason)
        XCTAssertTrue(e[3].isBare)
        XCTAssertFalse(e[3].isMain)
    }

    func testUnknownWorktreeLinesIgnored() {
        let e = GitPorcelain.parseWorktreeList(nul(["worktree /a", "HEAD x", "futureattr whatever", "locked", ""]))
        XCTAssertEqual(e.count, 1)
        XCTAssertTrue(e[0].isLocked)
        XCTAssertNil(e[0].lockReason)
    }

    func testParsesStatusHeadersAndCounts() {
        let d = nul([
            "# branch.oid abc123", "# branch.head feat", "# branch.upstream origin/feat", "# branch.ab +2 -1", "# stash 3",
            "1 M. N... 100644 100644 100644 h h staged.txt",
            "1 .M N... 100644 100644 100644 h h with space.txt",
            "1 MM N... 100644 100644 100644 h h both.txt",
            "u UU N... 1 2 3 4 h h h conflict.txt",
            "? new.txt", "? other.txt", "! ignored.txt",
        ])
        let r = GitPorcelain.parseStatus(d, truncated: false)
        XCTAssertEqual(r.oid, "abc123")
        XCTAssertEqual(r.headName, "feat")
        XCTAssertEqual(r.upstream, "origin/feat")
        XCTAssertEqual(r.ahead, 2)
        XCTAssertEqual(r.behind, 1)
        XCTAssertEqual(r.stashTotal, 3)
        XCTAssertEqual(r.workingTree.staged, 2)
        XCTAssertEqual(r.workingTree.unstaged, 2)
        XCTAssertEqual(r.workingTree.conflicted, 1)
        XCTAssertEqual(r.workingTree.untracked, 2)
        XCTAssertFalse(r.workingTree.isLowerBound)
        XCTAssertFalse(r.workingTree.isClean)
    }

    func testRenameEntryConsumesOrigPathField() {
        let d = nul([
            "2 R. N... 100644 100644 100644 h h R100 new.txt", "old.txt",
            "? untracked.txt",
        ])
        let r = GitPorcelain.parseStatus(d, truncated: false)
        XCTAssertEqual(r.workingTree.staged, 1)
        XCTAssertEqual(r.workingTree.untracked, 1)
    }

    func testInitialAndDetachedHeads() {
        let a = GitPorcelain.parseStatus(nul(["# branch.oid (initial)", "# branch.head main"]), truncated: false)
        XCTAssertEqual(a.oid, "(initial)")
        let b = GitPorcelain.parseStatus(nul(["# branch.oid abc", "# branch.head (detached)"]), truncated: false)
        XCTAssertEqual(b.headName, "(detached)")
        XCTAssertNil(b.upstream)
    }

    func testUpstreamGone() {
        let r = GitPorcelain.parseStatus(
            nul(["# branch.oid a", "# branch.head x", "# branch.upstream origin/x"]), truncated: false)
        XCTAssertEqual(r.upstream, "origin/x")
        XCTAssertNil(r.ahead)
    }

    func testSubmoduleDirtyCounted() {
        let d = nul([
            "1 .M S.M. 160000 160000 160000 h h dirtysub",
            "1 .M SC.. 160000 160000 160000 h h movedsub",
            "1 .M S... 160000 160000 160000 h h cleansub-but-y",
        ])
        let r = GitPorcelain.parseStatus(d, truncated: false)
        XCTAssertEqual(r.workingTree.submodulesDirty, 2)
        XCTAssertEqual(r.workingTree.unstaged, 1)
    }

    func testTruncatedStatusIsLowerBound() {
        let d = Data(("1 .M N... 100644 100644 100644 h h a.txt\0? b.txt\0? c.tx").utf8)
        let r = GitPorcelain.parseStatus(d, truncated: true)
        XCTAssertTrue(r.workingTree.isLowerBound)
        XCTAssertEqual(r.workingTree.untracked, 1)  // partial last record dropped
        XCTAssertEqual(r.workingTree.unstaged, 1)
    }

    func testParsesStashRecords() {
        let d = nul([
            "stash@{0}\u{1F}1700000100\u{1F}WIP on feat: abc msg",
            "stash@{1}\u{1F}1700000000\u{1F}On main: custom",
        ])
        let recs = GitPorcelain.parseStashList(d)
        XCTAssertEqual(recs.count, 2)
        let s = GitPorcelain.stashSummary(recs, branch: "feat")
        XCTAssertEqual(s.total, 2)
        XCTAssertEqual(s.mentioningBranch, 1)
        XCTAssertEqual(s.newestDate, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(GitPorcelain.stashSummary(recs, branch: "main").mentioningBranch, 1)
        XCTAssertEqual(GitPorcelain.stashSummary(recs, branch: "feat2").mentioningBranch, 0)
    }

    func testParsesRevParseDiscovery() {
        XCTAssertEqual(
            GitPorcelain.parseDiscovery("false\nfalse\n"),
            .init(isBare: false, isShallow: false, superproject: nil))
        XCTAssertEqual(
            GitPorcelain.parseDiscovery("false\ntrue\n/parent\n"),
            .init(isBare: false, isShallow: true, superproject: "/parent"))
        XCTAssertNil(GitPorcelain.parseDiscovery("garbage"))
    }

    func testParsesGitVersion() {
        let a = GitPorcelain.parseGitVersion("git version 2.39.5 (Apple Git-154)\n")
        XCTAssertEqual(a?.major, 2)
        XCTAssertEqual(a?.minor, 39)
        XCTAssertEqual(a?.patch, 5)
        XCTAssertEqual(GitPorcelain.parseGitVersion("git version 2.54.0.windows.1")?.minor, 54)
        XCTAssertNil(GitPorcelain.parseGitVersion("garbage"))
    }

    func testVersionGate() {
        XCTAssertFalse(GitPorcelain.isVersionSupported((2, 35, 9)))
        XCTAssertTrue(GitPorcelain.isVersionSupported((2, 36, 0)))
        XCTAssertTrue(GitPorcelain.isVersionSupported((3, 0, 0)))
    }
}
