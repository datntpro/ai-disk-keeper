import XCTest

@testable import DiskKeeperCore

final class GitInspectorProbeTests: XCTestCase {
    let base = "refs/remotes/origin/main"

    func testCherryAndMergeTreeAndAncestor() async throws {
        let s = try WorktreeScenario()
        let git = s.inspector()
        let ff = try s.ffMerged(), sq = try s.squashMerged(), cp = try s.cherryPicked(), um = try s.unmerged()

        // ff-merged: ancestor, cherry has nothing left, merge-tree equals base
        let ffAncestor = try await git.isAncestor("HEAD", of: base, in: ff)
        XCTAssertEqual(ffAncestor, true)
        // squash: not an ancestor, but cherry-equivalent fails (different patch id)
        let sqAncestor = try await git.isAncestor("HEAD", of: base, in: sq)
        XCTAssertEqual(sqAncestor, false)
        let sqTree = try await git.mergeTreeMatchesBase(base: base, in: sq)
        XCTAssertEqual(sqTree, true, "squash-merged branch adds nothing on top of main")
        // cherry-picked: git cherry shows all '-'
        let cpCherry = try await git.cherryAllApplied(base: base, in: cp)
        XCTAssertEqual(cpCherry, true)
        let cpAncestor = try await git.isAncestor("HEAD", of: base, in: cp)
        XCTAssertEqual(cpAncestor, false)
        // unmerged: all three negative
        let umCherry = try await git.cherryAllApplied(base: base, in: um)
        XCTAssertEqual(umCherry, false)
        let umTree = try await git.mergeTreeMatchesBase(base: base, in: um)
        XCTAssertEqual(umTree, false)
        let umAncestor = try await git.isAncestor("HEAD", of: base, in: um)
        XCTAssertEqual(umAncestor, false)
    }

    func testMergeTreeConflictIsFalse() async throws {
        let s = try WorktreeScenario()
        let w = try s.wt("conf")
        try s.fx.commit(w, file: "README.md", msg: "b", content: "branch\n")
        try s.fx.commit(s.repo, file: "README.md", msg: "m", content: "main\n")
        try s.advanceOrigin()
        let r = try await s.inspector().mergeTreeMatchesBase(base: base, in: w)
        XCTAssertEqual(r, false)
    }

    func testCommitsNotOnAnyRef() async throws {
        let s = try WorktreeScenario()
        let det = try s.detachedWithUnreachableCommit()
        let n = try await s.inspector().commitsNotOnAnyRef(in: det)
        XCTAssertEqual(n, 1)
        let um = try s.unmerged()
        let m = try await s.inspector().commitsNotOnAnyRef(in: um)
        XCTAssertEqual(m, 0, "a branch keeps its commits reachable")
    }

    func testUnknownRevisionIsNilNotFalse() async throws {
        let s = try WorktreeScenario()
        let w = try s.unmerged()
        let a = try await s.inspector().isAncestor("HEAD", of: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", in: w)
        XCTAssertNil(a)
        let c = try await s.inspector().cherryAllApplied(base: "refs/remotes/origin/nope", in: w)
        XCTAssertNil(c)
    }

    func testOriginURLReadsLocalConfig() async throws {
        let s = try WorktreeScenario()
        let u = try await s.inspector().originURL(in: s.repo)
        XCTAssertEqual(u, s.origin.path)
    }

    func testProbesRunWithoutOptionalLocks() {
        XCTAssertEqual(GitInspector.makeEnvironment(home: "/h")["GIT_OPTIONAL_LOCKS"], "0")
    }
}
