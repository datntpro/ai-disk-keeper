import XCTest
@testable import DiskKeeperCore

final class WorktreeAttributionTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var home: String { tmp.url.path }

    override func setUpWithError() throws { tmp = try TemporaryDirectory() }
    override func tearDown() { tmp = nil }

    private func mkdir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: tmp.path(rel), withIntermediateDirectories: true)
    }

    func testGitDirectory() throws {
        try mkdir("code/app/.git"); try mkdir("code/app/Sources/Deep")
        var a = WorktreeAttribution(home: home)
        let ref = try XCTUnwrap(a.root(forCWD: tmp.path("code/app/Sources/Deep")))
        XCTAssertEqual(ref.root, tmp.path("code/app"))
        XCTAssertEqual(ref.repoRoot, tmp.path("code/app"))
        XCTAssertFalse(ref.isLinkedWorktree)
        XCTAssertEqual(ref.displayName, "app")
        XCTAssertEqual(a.root(forCWD: tmp.path("code/app"))?.root, tmp.path("code/app"))
    }

    func testGitFileMapsLinkedWorktreeToMainRepo() throws {
        try mkdir("code/main/.git/worktrees/wt1"); try mkdir("wts/wt1/src")
        try tmp.file("wts/wt1/.git", contents: Data("gitdir: \(tmp.path("code/main/.git/worktrees/wt1"))\n".utf8))
        var a = WorktreeAttribution(home: home)
        let ref = try XCTUnwrap(a.root(forCWD: tmp.path("wts/wt1/src")))
        XCTAssertEqual(ref.root, tmp.path("wts/wt1"))
        XCTAssertEqual(ref.repoRoot, tmp.path("code/main"))
        XCTAssertTrue(ref.isLinkedWorktree)
        XCTAssertEqual(ref.displayName, "wt1")
    }

    func testRelativeGitFile() throws {
        try mkdir("code/main/.git/worktrees/wt"); try mkdir("code/main/wt")
        try tmp.file("code/main/wt/.git", contents: Data("gitdir: ../.git/worktrees/wt".utf8))
        var a = WorktreeAttribution(home: home)
        XCTAssertEqual(a.root(forCWD: tmp.path("code/main/wt"))?.repoRoot, tmp.path("code/main"))
    }

    func testSiblingPrefixIsNotMatched() throws {
        try mkdir("a/wt/.git"); try mkdir("a/wt2/sub")
        var a = WorktreeAttribution(home: home)
        XCTAssertNil(a.root(forCWD: tmp.path("a/wt2/sub")))
        XCTAssertEqual(a.root(forCWD: tmp.path("a/wt"))?.root, tmp.path("a/wt"))
    }

    func testNoRepoAndOutsideHomeAreNil() throws {
        try mkdir("plain/dir")
        var a = WorktreeAttribution(home: home)
        XCTAssertNil(a.root(forCWD: tmp.path("plain/dir")))
        XCTAssertNil(a.root(forCWD: "/usr/bin"))
        XCTAssertNil(a.root(forCWD: "relative/path"))
    }

    func testHomeItselfIsNeverAWorktree() throws {
        try mkdir(".git"); try mkdir("x")
        var a = WorktreeAttribution(home: home)
        XCTAssertNil(a.root(forCWD: tmp.path("x")), "a dotfiles repo in $HOME must not swallow every process")
    }

    func testMalformedGitFileIsNil() throws {
        try mkdir("bad/sub")
        try tmp.file("bad/.git", contents: Data("not a gitdir line".utf8))
        var a = WorktreeAttribution(home: home)
        XCTAssertNil(a.root(forCWD: tmp.path("bad/sub")))
    }

    func testOversizedGitFileIsReadOnlyUpTo4KiB() throws {
        try mkdir("big")
        try tmp.file("big/.git", contents: Data(repeating: 0x78, count: 1 << 20))
        var a = WorktreeAttribution(home: home)
        XCTAssertNil(a.root(forCWD: tmp.path("big")))
    }
}
