import XCTest

@testable import DiskKeeperCore

final class WorktreeClassifierTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var settings: AppSettings { AppSettings() }

    func baseGit() -> GitState {
        GitState(
            path: "/w/a", kind: .linkedWorktree, gitDir: "/r/.git/worktrees/a", commonDir: "/r/.git",
            head: .branch(name: "feat", oid: "abc"), commitsNotOnAnyRemote: .init(value: 0, isCapped: false),
            workingTree: .init(), defaultBranch: .init(ref: "refs/remotes/origin/main", source: .originHEAD),
            isMergedIntoDefault: true,
            ignored: .init(count: 0, isLowerBound: false, preciousPaths: [], unclassifiedPaths: []),
            hiddenFromStatus: .init(), submodules: [])
    }

    func baseFacts() -> WorktreeFacts {
        WorktreeFacts(
            worktree: DiscoveredWorktree(path: "/w/a", repoPath: "/r", sources: [.git]), git: baseGit(),
            cherryAllApplied: false, mergeTreeMatchesBase: false, baseRef: "refs/remotes/origin/main", pr: .disabled,
            processes: [], lastActivity: .init(date: now.addingTimeInterval(-10 * 3600), source: .index), pathAllowed: true)
    }

    func verdict(_ f: WorktreeFacts) -> SafeCleanVerdict { WorktreeClassifier.verdict(f, now: now, settings: settings) }

    func failing(_ v: SafeCleanVerdict) -> [WorktreeCheckID] { v.checks.filter { $0.passed != true }.map(\.id) }

    func testAllPassIsEligibleAndSafe() {
        let v = verdict(baseFacts())
        XCTAssertTrue(v.eligible)
        XCTAssertEqual(v.tier, .safe)
        XCTAssertEqual(v.checks.map(\.id), WorktreeCheckID.allCases)
        XCTAssertEqual(v.check(.workDone)?.evidence, .ancestorOf(ref: "origin/main"))
    }

    func testEachCheckAloneBlocks() {
        var cases: [(WorktreeCheckID, (inout WorktreeFacts) -> Void, WorktreeTier)] = []
        cases.append((.notMain, { $0.worktree.isMain = true }, .keep))
        cases.append((.notMain, { $0.worktree.isBare = true }, .keep))
        cases.append((.notMain, { $0.containsOwnCWD = true }, .keep))
        cases.append((.notMain, { $0.pathAllowed = false }, .keep))
        cases.append((.workDone, { $0.git?.isMergedIntoDefault = false }, .review))
        cases.append((.clean, { $0.git?.workingTree = .init(untracked: 1) }, .keep))
        cases.append((.clean, { $0.git?.operationInProgress = .rebase }, .keep))
        cases.append((.clean, { $0.git?.indexLockPresent = true }, .keep))
        cases.append((.clean, { $0.git?.worktreeLock = .init(reason: nil) }, .keep))
        cases.append((.clean, { $0.git?.hiddenFromStatus = .init(skipWorktree: 1) }, .keep))
        cases.append((.clean, { $0.git?.uninspectedSubmodules = 1 }, .keep))
        cases.append((.noPreciousIgnored, { $0.git?.ignored = .init(count: 1, isLowerBound: false, preciousPaths: [".env"], unclassifiedPaths: []) }, .keep))
        cases.append((.commitsSafe, { f in
            f.git?.head = .detached(oid: "abc")
            f.commitsNotOnAnyRef = 2
        }, .keep))
        cases.append((.noProcess, { $0.processes = [WorktreeProcess(pid: 9, name: "node", agent: nil)] }, .keep))
        cases.append((.noProcess, { $0.openFileHolders = 1 }, .keep))
        cases.append((.idle, { $0.lastActivity = .init(date: self.now.addingTimeInterval(-60), source: .files) }, .keep))
        for (id, mutate, tier) in cases {
            var f = baseFacts()
            mutate(&f)
            let v = verdict(f)
            XCTAssertFalse(v.eligible, "\(id)")
            XCTAssertEqual(failing(v), [id], "only \(id) should fail")
            XCTAssertEqual(v.tier, tier, "\(id)")
        }
    }

    func testUnknownIsNotEligible() {
        var cases: [(WorktreeCheckID, (inout WorktreeFacts) -> Void)] = []
        cases.append((.notMain, { $0.pathAllowed = nil }))
        cases.append((.clean, { $0.git?.workingTree = nil }))
        cases.append((.clean, { $0.git?.probeFailures = [.init(probe: .status, kind: .timedOut, message: "")] }))
        cases.append((.noPreciousIgnored, { $0.git?.ignored = nil }))
        cases.append((.noPreciousIgnored, { $0.git?.ignored = .init(count: 9, isLowerBound: true, preciousPaths: [], unclassifiedPaths: []) }))
        cases.append((.commitsSafe, { $0.git?.head = nil }))
        cases.append((.commitsSafe, { f in
            f.git?.head = .detached(oid: "a")
            f.commitsNotOnAnyRef = nil
        }))
        cases.append((.noProcess, { $0.processes = nil }))
        cases.append((.idle, { $0.lastActivity = nil }))
        for (id, mutate) in cases {
            var f = baseFacts()
            mutate(&f)
            let v = verdict(f)
            XCTAssertNil(v.check(id)?.passed, "\(id)")
            XCTAssertFalse(v.eligible)
            XCTAssertNotEqual(v.tier, .safe)
        }
        var noGit = baseFacts()
        noGit.git = nil
        noGit.gitError = "boom"
        XCTAssertFalse(verdict(noGit).eligible)
    }

    func testWorkDoneMethods() {
        func f(_ m: (inout WorktreeFacts) -> Void) -> WorktreeCheck {
            var x = baseFacts()
            x.git?.isMergedIntoDefault = false
            m(&x)
            return WorktreeClassifier.workDone(x)
        }
        XCTAssertEqual(f { $0.cherryAllApplied = true }.evidence, .cherryApplied(ref: "origin/main"))
        XCTAssertEqual(f { $0.mergeTreeMatchesBase = true }.evidence, .mergeTreeEquals(ref: "origin/main"))
        XCTAssertEqual(f { _ in }.passed, false)   // everything answered "no"
        XCTAssertEqual(f { $0.mergeTreeMatchesBase = nil }.passed, nil)   // one proof unknown
    }

    func testUnpushedCommitsNeverProveWorkDone() {
        func f(_ m: (inout WorktreeFacts) -> Void) -> WorktreeCheck {
            var x = baseFacts()
            x.git?.isMergedIntoDefault = false
            m(&x)
            return WorktreeClassifier.workDone(x)
        }
        let unpushed = GitState.Count(value: 2, isCapped: false)
        // content proven by cherry / merge-tree but commits exist on no remote
        var c = f { $0.cherryAllApplied = true; $0.git?.commitsNotOnAnyRemote = unpushed }
        XCTAssertEqual(c.passed, false)
        XCTAssertEqual(c.evidence, .unpushedCommits(count: 2))
        c = f { $0.mergeTreeMatchesBase = true; $0.git?.commitsNotOnAnyRemote = unpushed }
        XCTAssertEqual(c.passed, false)
        // remote state unknown or capped: unknown, never a pass
        XCTAssertNil(f { $0.cherryAllApplied = true; $0.git?.commitsNotOnAnyRemote = nil }.passed)
        XCTAssertNotEqual(f { $0.cherryAllApplied = true; $0.git?.commitsNotOnAnyRemote = .init(value: 0, isCapped: true) }.passed, true)
        // a proof against a local-only default branch is not a remote proof
        c = f { $0.baseRef = "refs/heads/main"; $0.cherryAllApplied = true }
        XCTAssertNotEqual(c.passed, true)
        var local = baseFacts()
        local.baseRef = "refs/heads/main"
        local.git?.isMergedIntoDefault = true
        XCTAssertNotEqual(WorktreeClassifier.workDone(local).passed, true)
        // pushed + proven passes
        XCTAssertEqual(f { $0.cherryAllApplied = true }.passed, true)
    }

    func testPRMatchingRules() {
        func f(_ pr: PRState, covered: Bool? = nil, remote: Int? = 0, local: Bool = false) -> WorktreeCheck {
            var x = baseFacts()
            x.git?.isMergedIntoDefault = local
            x.pr = pr
            x.headCoveredByMergedPR = covered
            x.git?.commitsNotOnAnyRemote = remote.map { .init(value: $0, isCapped: false) }
            return WorktreeClassifier.workDone(x)
        }
        // merged + HEAD covered by the PR head -> done
        XCTAssertEqual(f(.merged(number: 7, headOID: "abc1234", url: nil), covered: true).evidence, .mergedPR(number: 7))
        // merged but HEAD moved after the merge -> not done
        XCTAssertEqual(f(.merged(number: 7, headOID: "abc1234", url: nil), covered: false).passed, false)
        // closed + all commits on a remote -> done; closed + unpushed -> not
        XCTAssertEqual(f(.closed(number: 3, url: nil)).evidence, .closedPRAllPushed(number: 3))
        XCTAssertEqual(f(.closed(number: 3, url: nil), remote: 2).passed, false)
        // open -> not done
        XCTAssertEqual(f(.open(number: 4, url: nil)).passed, false)
        // gh off -> unknown to PR logic, local proof still works
        XCTAssertEqual(f(.disabled, local: true).passed, true)
        // gh failed -> unknown, but local proof still wins
        XCTAssertNil(f(.unknown(reason: "x")).passed)
        XCTAssertEqual(f(.unknown(reason: "x"), local: true).passed, true)
    }

    func testOrphanIsReview() {
        var f = baseFacts()
        f.worktree.isOrphan = true
        f.git = nil
        let v = verdict(f)
        XCTAssertEqual(v.tier, .review)
        XCTAssertFalse(v.eligible)
    }

    func testIdleHoursSetting() {
        var s = AppSettings()
        s.worktreeIdleHours = 12
        let f = baseFacts()   // idle for 10 h
        XCTAssertEqual(WorktreeClassifier.verdict(f, now: now, settings: s).check(.idle)?.passed, false)
        s.worktreeIdleHours = 3
        XCTAssertEqual(WorktreeClassifier.verdict(f, now: now, settings: s).check(.idle)?.passed, true)
    }

    func testSettingsDefaultsAndClamp() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(s.worktreeIdleHours, 3)
        XCTAssertFalse(s.useGitHubCLIForPRs)
        let t = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"worktreeIdleHours":500,"useGitHubCLIForPRs":true}"#.utf8))
        XCTAssertEqual(t.worktreeIdleHours, 72)
        XCTAssertTrue(t.useGitHubCLIForPRs)
    }
}
