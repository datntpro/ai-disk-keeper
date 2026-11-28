import XCTest

@testable import DiskKeeperCore

final class WorktreeInventoryTests: XCTestCase {
    func rows(_ s: WorktreeScenario, _ inv: WorktreeInventory) async -> [String: WorktreeRow] {
        let r = await inv.refresh(settings: AppSettings())
        return Dictionary(uniqueKeysWithValues: r.rows.map { ($0.name, $0) })
    }

    func testTruthTable() async throws {
        let s = try WorktreeScenario()
        _ = try s.ffMerged(); _ = try s.squashMerged(); _ = try s.cherryPicked(); _ = try s.unmerged()
        _ = try s.squashMerged(name: "sqp", pushBranch: true); _ = try s.cherryPicked(name: "cpp", pushBranch: true)
        let dirty = try s.wt("dirty", commit: true)
        try s.fx.write(dirty, "README.md", "changed\n")
        let untracked = try s.wt("untracked")
        try s.fx.write(untracked, "new.txt")
        let env = try s.wt("env")
        try s.fx.write(env, ".env", "SECRET=1\n")
        _ = try s.detachedWithUnreachableCommit()
        let locked = try s.wt("locked")
        try s.fx.git(["worktree", "lock", locked.path], in: s.repo)
        _ = try s.rebaseInProgress()
        _ = try s.orphan()
        let r = try await rows(s, s.inventory())

        for name in ["ff", "sqp", "cpp"] {
            XCTAssertTrue(r[name]?.verdict.eligible == true, "\(name): \(String(describing: r[name]?.verdict.checks))")
            XCTAssertEqual(r[name]?.verdict.tier, .safe)
        }
        func only(_ name: String, fails id: WorktreeCheckID, tier: WorktreeTier, file: StaticString = #filePath, line: UInt = #line) {
            guard let v = r[name]?.verdict else { return XCTFail("missing \(name)", file: file, line: line) }
            XCTAssertFalse(v.eligible, name, file: file, line: line)
            XCTAssertEqual(v.checks.filter { $0.passed != true }.map(\.id), [id], "\(name) \(v.checks)", file: file, line: line)
            XCTAssertEqual(v.tier, tier, name, file: file, line: line)
        }
        only("um", fails: .workDone, tier: .review)
        // Content is in origin/main but the branch itself was never pushed: not provably safe to forget.
        only("sq", fails: .workDone, tier: .review)
        only("cp", fails: .workDone, tier: .review)
        XCTAssertEqual(r["sq"]?.verdict.check(.workDone)?.evidence, .unpushedCommits(count: 1))
        // a dirty/untracked tree also has unproven work; the first blocker must still be the tree
        XCTAssertEqual(r["dirty"]?.verdict.check(.clean)?.passed, false)
        XCTAssertEqual(r["dirty"]?.verdict.tier, .keep)
        XCTAssertEqual(r["untracked"]?.verdict.check(.clean)?.passed, false)
        XCTAssertEqual(r["env"]?.verdict.check(.noPreciousIgnored)?.passed, false)
        XCTAssertEqual(r["env"]?.verdict.tier, .keep)
        XCTAssertEqual(r["det"]?.verdict.check(.commitsSafe)?.passed, false)
        XCTAssertEqual(r["locked"]?.verdict.check(.clean)?.passed, false)
        XCTAssertEqual(r["reb"]?.verdict.check(.clean)?.passed, false)
        XCTAssertEqual(r["orph"]?.verdict.tier, .review)
        XCTAssertEqual(r["orph"]?.facts.worktree.isOrphan, true)
        XCTAssertFalse(r["orph"]?.verdict.eligible ?? true)
        // main checkout is context, never a candidate
        XCTAssertNil(r["proj"])
    }

    func testProcessBlocksAndSiblingPrefixDoesNot() async throws {
        let s = try WorktreeScenario()
        let w = try s.ffMerged()
        let sibling = try s.wt("ff-other")   // path shares the "ff" prefix
        let procs = FakeProcessTable([
            ProcessRecord(pid: 100, ppid: 1, name: "node", cwd: w.path + "/sub"),
            ProcessRecord(pid: 101, ppid: 1, name: "node", cwd: sibling.path + "x"),
        ])
        let r = await rows(s, try s.inventory(processes: procs))
        XCTAssertEqual(r["ff"]?.verdict.check(.noProcess)?.passed, false)
        XCTAssertEqual(r["ff"]?.facts.processes?.map(\.pid), [100])
        XCTAssertEqual(r["ff-other"]?.facts.processes?.count, 0)
    }

    func testUnreadableProcessTableFailsClosed() async throws {
        let s = try WorktreeScenario()
        _ = try s.ffMerged()
        let result = try await s.inventory(processes: FakeProcessTable(nil)).refresh(settings: AppSettings())
        XCTAssertNil(result.rows.first { $0.name == "ff" }?.verdict.check(.noProcess)?.passed)
        XCTAssertFalse(result.rows.first { $0.name == "ff" }?.verdict.eligible ?? true)
        XCTAssertTrue(result.warnings.contains(.processTableUnreadable))
    }

    func testOwnCWDIsNeverEligible() async throws {
        let s = try WorktreeScenario()
        let w = try s.ffMerged()
        let r = await rows(s, try s.inventory(ownCWDs: [w.path + "/deep"]))
        XCTAssertEqual(r["ff"]?.verdict.check(.notMain)?.passed, false)
    }

    func testRecentActivityBlocks() async throws {
        let s = try WorktreeScenario()
        _ = try s.ffMerged()
        let r = await rows(s, try s.inventory(now: Date()))
        XCTAssertEqual(r["ff"]?.verdict.check(.idle)?.passed, false)
        XCTAssertEqual(r["ff"]?.verdict.tier, .keep)
    }

    func testOrcaActivityCountsAndDedupe() async throws {
        let s = try WorktreeScenario()
        let w = try s.ffMerged()
        let soon = Date().addingTimeInterval(86400 * 40)
        let orca = OrcaListResult(rows: [OrcaWorktreeRow(path: w.path, branch: "ff", lastActivityAt: soon)])
        let result = try await s.inventory(orca: orca, now: soon.addingTimeInterval(60)).refresh(settings: AppSettings())
        let matches = result.rows.filter { $0.name == "ff" }
        XCTAssertEqual(matches.count, 1, "Orca and git list the same worktree once")
        XCTAssertTrue(matches.first!.facts.worktree.sources.isSuperset(of: [.orca, .git]))
        XCTAssertEqual(matches.first?.facts.lastActivity?.source, .orca)
        XCTAssertEqual(matches.first?.verdict.check(.idle)?.passed, false)
    }

    func testSymlinkedPathDedupes() async throws {
        let s = try WorktreeScenario()
        let w = try s.ffMerged()
        let link = s.fx.tmp.path("link-to-ff")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: w.path)
        let orca = OrcaListResult(rows: [OrcaWorktreeRow(path: link, branch: "ff")])
        let result = try await s.inventory(orca: orca).refresh(settings: AppSettings())
        XCTAssertEqual(result.rows.filter { $0.name == "ff" }.count, 1)
        XCTAssertEqual(result.rows.first { $0.name == "ff" }?.path, w.path)
    }

    func testOrcaMissingOnlyWarns() async throws {
        let s = try WorktreeScenario()
        _ = try s.ffMerged()
        let result = try await s.inventory(orca: OrcaListResult(warning: "Orca is not installed")).refresh(settings: AppSettings())
        XCTAssertEqual(result.warnings, [.orcaUnavailable("Orca is not installed")])
        XCTAssertEqual(result.rows.count, 1)
    }

    func testGitHubOffNeverCallsSource() async throws {
        struct Boom: PRStatusSource {
            func lookup(repository: String, remoteURL: String?) async -> PRLookup { XCTFail("must not be called"); return .records([]) }
        }
        let s = try WorktreeScenario()
        _ = try s.unmerged()
        let result = try await s.inventory(pr: Boom()).refresh(settings: AppSettings())
        XCTAssertEqual(result.rows.first?.facts.pr, .disabled)
    }

    func testGitHubOnUsesMergedPRAndHeadMovedIsNotDone() async throws {
        let s = try WorktreeScenario()
        let w = try s.unmerged()   // not in main by any local proof
        let head = try s.fx.git(["rev-parse", "HEAD"], in: w).trimmingCharacters(in: .whitespacesAndNewlines)
        var settings = AppSettings()
        settings.useGitHubCLIForPRs = true
        let merged = PRRecord(number: 9, state: "MERGED", headRefName: "um", headRefOid: head, mergedAt: Date())
        var r = try await s.inventory(pr: FakePRSource(lookupResult: .records([merged]))).refresh(settings: settings)
        XCTAssertEqual(r.rows.first?.verdict.check(.workDone)?.evidence, .mergedPR(number: 9))
        XCTAssertTrue(r.rows.first?.verdict.eligible == true)

        // HEAD moves after the merge -> no longer covered
        try s.fx.commit(w, file: "after.txt", msg: "after merge")
        r = try await s.inventory(pr: FakePRSource(lookupResult: .records([merged]))).refresh(settings: settings)
        XCTAssertEqual(r.rows.first?.verdict.check(.workDone)?.passed, false)

        // gh unavailable -> unknown + warning
        r = try await s.inventory(pr: FakePRSource(lookupResult: .unavailable("not signed in"))).refresh(settings: settings)
        XCTAssertNil(r.rows.first?.verdict.check(.workDone)?.passed)
        XCTAssertTrue(r.warnings.contains { if case .prLookupFailed = $0 { return true } else { return false } })
    }

    func testDiscoveryFindsInRepoFoldersAndSkipsSubmodules() async throws {
        let s = try WorktreeScenario()
        let folder = s.repo.appendingPathComponent(".claude/worktrees/agent")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.fx.git(["worktree", "add", "-q", "-b", "agent", folder.path], in: s.repo)
        let inv = WorktreeInventory(dependencies: .init(
            git: s.inspector(), orca: StaticOrcaWorktrees(), processes: FakeProcessTable([]), protectedPaths: try s.protectedPaths(),
            home: s.fx.home, projectRoots: [s.fx.root.path], ownCWDs: ["/"], workspaceParents: [], inRepoFolders: [".claude/worktrees"]))
        let result = await inv.refresh(settings: AppSettings())
        let found = result.rows.first { $0.name == "agent" }
        XCTAssertNotNil(found)
        XCTAssertTrue(found?.facts.worktree.sources.contains(.root) == true)
    }

    func testGitDirIsByteUnchanged() async throws {
        let s = try WorktreeScenario()
        _ = try s.squashMerged(name: "sqp", pushBranch: true)
        _ = try s.unmerged()
        _ = try s.cherryPicked()
        let before = treeSnapshot(s.repo.path + "/.git")
        _ = try await s.inventory().refresh(settings: AppSettings())
        let after = treeSnapshot(s.repo.path + "/.git")
        let changed = Set(before.keys).symmetricDifference(after.keys).union(before.keys.filter { after[$0] != before[$0] })
        var detail = ""
        for path in changed.sorted() where path.hasPrefix("objects/") {
            let oid = path.replacingOccurrences(of: "objects/", with: "").replacingOccurrences(of: "/", with: "")
            detail += (try? s.fx.git(["cat-file", "-t", oid], in: s.repo, allowFail: true)) ?? ""
            detail += (try? s.fx.git(["cat-file", "-p", oid], in: s.repo, allowFail: true)) ?? ""
        }
        XCTAssertEqual(changed.sorted(), [], "an inventory must not write anything into .git: \(detail)")
    }

    /// A clone that borrows its objects (`objects/info/alternates`): neither repository may change.
    func testAlternatesRepositoryIsByteUnchanged() async throws {
        let s = try WorktreeScenario()
        _ = try s.squashMerged(name: "sqp", pushBranch: true)
        let clone = s.fx.root.appendingPathComponent("shared-clone")
        try s.fx.git(["clone", "-q", "--shared", s.repo.path, clone.path], in: s.fx.root)
        let alternates = try String(contentsOfFile: clone.path + "/.git/objects/info/alternates", encoding: .utf8)
        XCTAssertTrue(alternates.contains(s.repo.path), "fixture must really use alternates")
        let wt = s.wtRoot.appendingPathComponent("alt")
        try s.fx.git(["worktree", "add", "-q", "-b", "alt", wt.path, "origin/main"], in: clone)
        try s.fx.commit(wt, file: "alt.txt", msg: "alt work")
        let beforeClone = treeSnapshot(clone.path + "/.git"), beforeOrigin = treeSnapshot(s.repo.path + "/.git")
        let result = try await s.inventory().refresh(settings: AppSettings())
        XCTAssertNotNil(result.rows.first { $0.name == "alt" }, "the alternates clone's worktree is inventoried")
        XCTAssertEqual(treeSnapshot(clone.path + "/.git"), beforeClone)
        XCTAssertEqual(treeSnapshot(s.repo.path + "/.git"), beforeOrigin)
    }

    func testNothingIsModified() async throws {
        let s = try WorktreeScenario()
        let w = try s.ffMerged()
        let before = try s.fx.git(["worktree", "list", "--porcelain"], in: s.repo)
        let headBefore = try s.fx.git(["rev-parse", "HEAD"], in: w)
        _ = try await s.inventory().refresh(settings: AppSettings())
        XCTAssertEqual(try s.fx.git(["worktree", "list", "--porcelain"], in: s.repo), before)
        XCTAssertEqual(try s.fx.git(["rev-parse", "HEAD"], in: w), headBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.path))
    }
}
