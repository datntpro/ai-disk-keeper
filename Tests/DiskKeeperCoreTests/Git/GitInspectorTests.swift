import Darwin
import XCTest

@testable import DiskKeeperCore

final class GitInspectorTests: XCTestCase {
    private func realpathString(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    // MARK: hardening

    func testHardenedEnvironmentIsUsed() async throws {
        let fx = try GitFixture()
        let insp = fx.inspector(gitExecutable: URL(fileURLWithPath: "/usr/bin/env")) { $0.rawMode = true }
        let dir = try fx.tmp.dir("a/b")
        let r = try await insp.runGit([], in: dir)
        let lines = Set(r.stdoutString.split(separator: "\n").map(String.init))
        for l in ["GIT_OPTIONAL_LOCKS=0", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
                  "GIT_TERMINAL_PROMPT=0", "GIT_CEILING_DIRECTORIES=\(realpathString(fx.tmp.path("a")))",
                  "PATH=/usr/bin:/bin:/usr/sbin:/sbin"] {
            XCTAssertTrue(lines.contains(l), "missing \(l)")
        }
        XCTAssertFalse(lines.contains { $0.hasPrefix("GIT_DIR=") || $0.hasPrefix("GIT_WORK_TREE=") })
        let pure = GitInspector.makeEnvironment(home: fx.home)
        XCTAssertEqual(pure["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(pure["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertNil(pure["GIT_DIR"])
    }

    func testBaseArgumentsDisableHooksFsmonitorAndNetwork() {
        let a = GitInspector.baseArguments(excludesFile: "/x/ign").joined(separator: " ")
        XCTAssertTrue(a.contains("core.hooksPath=/dev/null"))
        XCTAssertTrue(a.contains("core.fsmonitor=false"))
        XCTAssertTrue(a.contains("protocol.allow=never"))
        XCTAssertTrue(a.contains("core.excludesFile=/x/ign"))
        XCTAssertFalse(GitInspector.baseArguments(excludesFile: nil).joined(separator: " ").contains("excludesFile"))
    }

    func testGitUnavailableWhenNotLocatable() async throws {
        XCTAssertNil(GitInspector.locateGit(environment: [:], fileExists: { _ in false }, developerDir: { nil }))
        XCTAssertEqual(
            GitInspector.locateGit(environment: ["AIDK_GIT": "/custom/git"], fileExists: { $0 == "/custom/git" }, developerDir: { nil })?.path,
            "/custom/git")
        XCTAssertEqual(
            GitInspector.locateGit(environment: [:], fileExists: { $0 == "/dev/usr/bin/git" }, developerDir: { "/dev" })?.path,
            "/dev/usr/bin/git")
        let fx = try GitFixture()
        let insp = fx.inspector(gitExecutable: URL(fileURLWithPath: "/nonexistent/git"))
        let repo = try fx.makeRepo("r")
        do {
            _ = try await insp.inspect(repo)
            XCTFail("expected error")
        } catch let e as GitInspectorError {
            XCTAssertEqual(e, .gitUnavailable)
        }
    }

    // MARK: states

    func testCleanAndMerged() async throws {
        let fx = try GitFixture()
        let (repo, _) = try fx.makeRepoWithOrigin("main-repo")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addWorktree(repo, wt, branch: "feat")
        try fx.commit(wt, file: "f.txt", msg: "feat work")
        try fx.push(wt, "feat", setUpstream: true)
        try fx.git(["merge", "-q", "--no-ff", "-m", "merge", "feat"], in: repo)
        try fx.push(repo, "main")
        let s = try await fx.inspector().inspect(wt)
        XCTAssertEqual(s.kind, .linkedWorktree)
        XCTAssertEqual(s.workingTree?.isClean, true)
        XCTAssertEqual(s.isMergedIntoDefault, true)
        XCTAssertEqual(s.upstream, .tracking(ref: "origin/feat", ahead: 0, behind: 0))
        XCTAssertEqual(s.commitsNotOnAnyRemote, .init(value: 0, isCapped: false))
        XCTAssertEqual(s.stash?.mentioningBranch, 0)
        XCTAssertEqual(s.defaultBranch, .init(ref: "refs/remotes/origin/main", source: .originHEAD))
        XCTAssertEqual(s.hasRemotes, true)
        XCTAssertNotNil(s.lastCommit)
        XCTAssertEqual(s.lastCommit?.subject, "feat work")
        XCTAssertEqual(s.probeFailures, [])
        XCTAssertEqual(s.topLevel, wt.path)
    }

    func testMainWorktreeKind() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.kind, .mainWorktree)
        XCTAssertEqual(s.defaultBranch, .init(ref: "refs/heads/main", source: .fallback))
    }

    func testDirtyTracked() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.write(repo, "README.md", "changed\n")
        let w = try await fx.inspector().inspect(repo).workingTree
        XCTAssertEqual(w?.unstaged, 1)
        XCTAssertEqual(w?.staged, 0)
        XCTAssertEqual(w?.isClean, false)
    }

    func testStagedOnly() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.write(repo, "new.txt")
        try fx.git(["add", "new.txt"], in: repo)
        let w = try await fx.inspector().inspect(repo).workingTree
        XCTAssertEqual(w?.staged, 1)
        XCTAssertEqual(w?.unstaged, 0)
        XCTAssertEqual(w?.untracked, 0)
    }

    func testUntrackedOnly() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.write(repo, "u.txt")
        let w = try await fx.inspector().inspect(repo).workingTree
        XCTAssertEqual(w?.untracked, 1)
        XCTAssertEqual(w?.staged, 0)
        XCTAssertEqual(w?.unstaged, 0)
    }

    func testGlobalExcludesFileHonored() async throws {
        let fx = try GitFixture()
        let ign = fx.root.appendingPathComponent("ign")
        try "junk\n".write(to: ign, atomically: true, encoding: .utf8)
        try "[core]\n\texcludesFile = \(ign.path)\n".write(
            toFile: fx.home + "/.gitconfig", atomically: true, encoding: .utf8)
        let repo = try fx.makeRepo("r")
        try fx.write(repo, "junk")
        let insp = fx.inspector()
        let a = try await insp.inspect(repo)
        XCTAssertEqual(a.workingTree?.untracked, 0)
        try fx.write(repo, "other")
        let b = try await insp.inspect(repo)
        XCTAssertEqual(b.workingTree?.untracked, 1)
    }

    func testUnpushedCommits() async throws {
        let fx = try GitFixture()
        let (repo, _) = try fx.makeRepoWithOrigin("r")
        try fx.commit(repo, file: "a", msg: "a")
        try fx.commit(repo, file: "b", msg: "b")
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.upstream, .tracking(ref: "origin/main", ahead: 2, behind: 0))
        XCTAssertEqual(s.commitsNotOnAnyRemote, .init(value: 2, isCapped: false))
    }

    func testRevListCap() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.commit(repo, file: "a", msg: "a")
        try fx.commit(repo, file: "b", msg: "b")
        let s = try await fx.inspector { $0.revListCap = 2 }.inspect(repo)
        XCTAssertEqual(s.commitsNotOnAnyRemote, .init(value: 2, isCapped: true))
    }

    func testNoUpstream() async throws {
        let fx = try GitFixture()
        let (repo, _) = try fx.makeRepoWithOrigin("r")
        try fx.git(["checkout", "-q", "-b", "topic"], in: repo)
        try fx.commit(repo, file: "t", msg: "t")
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.upstream, GitState.Upstream.none)
        XCTAssertEqual(s.commitsNotOnAnyRemote, .init(value: 1, isCapped: false))
        XCTAssertEqual(s.isMergedIntoDefault, false)
    }

    func testNoRemotesAtAll() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.commit(repo, file: "a", msg: "a")
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.hasRemotes, false)
        XCTAssertEqual(s.commitsNotOnAnyRemote, .init(value: 2, isCapped: false))
    }

    func testUpstreamGone() async throws {
        let fx = try GitFixture()
        let (repo, origin) = try fx.makeRepoWithOrigin("r")
        try fx.git(["checkout", "-q", "-b", "topic"], in: repo)
        try fx.commit(repo, file: "t", msg: "t")
        try fx.push(repo, "topic", setUpstream: true)
        try fx.git(["branch", "-D", "topic"], in: origin)
        try fx.git(["fetch", "-q", "--prune"], in: repo)
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.upstream, .gone(ref: "origin/topic"))
    }

    func testDetachedHead() async throws {
        let fx = try GitFixture()
        let (repo, _) = try fx.makeRepoWithOrigin("r")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addDetachedWorktree(repo, wt)
        let s = try await fx.inspector().inspect(wt)
        guard case .detached? = s.head else { return XCTFail("\(String(describing: s.head))") }
        XCTAssertEqual(s.upstream, GitState.Upstream.none)
        XCTAssertEqual(s.isMergedIntoDefault, true)
    }

    func testStashPresentAttributedToBranch() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addWorktree(repo, wt, branch: "feat")
        try fx.write(wt, "README.md", "dirty\n")
        try fx.git(["stash", "-q"], in: wt)
        let insp = fx.inspector()
        let f = try await insp.inspect(wt).stash
        XCTAssertEqual(f?.total, 1)
        XCTAssertEqual(f?.mentioningBranch, 1)
        XCTAssertNotNil(f?.newestDate)
        let m = try await insp.inspect(repo).stash
        XCTAssertEqual(m?.total, 1)
        XCTAssertEqual(m?.mentioningBranch, 0)
    }

    func testLockedWorktree() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addWorktree(repo, wt, branch: "feat")
        try fx.git(["worktree", "lock", "--reason", "agent busy", wt.path], in: repo)
        let insp = fx.inspector()
        let s = try await insp.inspect(wt)
        XCTAssertEqual(s.worktreeLock, .init(reason: "agent busy"))
        let list = try await insp.listWorktrees(of: repo)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].isMain)
        XCTAssertEqual(list.first { $0.path == wt.path }?.isLocked, true)
        XCTAssertEqual(list.first { $0.path == wt.path }?.lockReason, "agent busy")
    }

    func testMissingWorktreeDirectory() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addWorktree(repo, wt, branch: "feat")
        try FileManager.default.removeItem(at: wt)
        let insp = fx.inspector()
        do {
            _ = try await insp.inspect(wt)
            XCTFail("expected error")
        } catch let e as GitInspectorError {
            XCTAssertEqual(e, .pathNotFound(wt.path))
        }
        let list = try await insp.listWorktrees(of: repo)
        XCTAssertEqual(list.first { $0.path == wt.path }?.isPrunable, true)
    }

    func testOrphanedGitFile() async throws {
        let fx = try GitFixture()
        let dir = try fx.tmp.dir("orphan")
        try "gitdir: /nonexistent/gitdir/worktrees/x\n".write(
            to: dir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let info = GitInspector.readGitFile(in: dir)
        XCTAssertEqual(info?.gitdir, "/nonexistent/gitdir/worktrees/x")
        XCTAssertEqual(info?.gitdirExists, false)
        do {
            _ = try await fx.inspector().inspect(dir)
            XCTFail("expected error")
        } catch let e as GitInspectorError {
            XCTAssertEqual(e, .orphanedWorktree(gitdir: "/nonexistent/gitdir/worktrees/x"))
        }
    }

    func testReadGitFileOfLinkedWorktree() throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addWorktree(repo, wt, branch: "feat")
        let info = GitInspector.readGitFile(in: wt)
        XCTAssertEqual(info?.gitdirExists, true)
        XCTAssertNotNil(info?.commonDir)
        XCTAssertNil(GitInspector.readGitFile(in: repo))  // .git is a directory
    }

    func testNotARepoInsideEnclosingRepo() async throws {
        let fx = try GitFixture()
        let enclosing = try fx.makeRepo("dotfiles")
        let plain = try fx.tmp.dir("dotfiles/plain")
        _ = enclosing
        do {
            _ = try await fx.inspector().inspect(plain)
            XCTFail("expected error")
        } catch let e as GitInspectorError {
            XCTAssertEqual(e, .notARepository(plain.path))
        }
    }

    func testNotADirectory() async throws {
        let fx = try GitFixture()
        let f = try fx.tmp.file("f.txt", bytes: 3)
        do {
            _ = try await fx.inspector().inspect(f)
            XCTFail("expected error")
        } catch let e as GitInspectorError {
            XCTAssertEqual(e, .notADirectory(f.path))
        }
    }

    func testUnbornRepo() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r", commit: false)
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.head, .unborn(branch: "main"))
        XCTAssertNil(s.lastCommit)
        XCTAssertNil(s.isMergedIntoDefault)
        XCTAssertNil(s.commitsNotOnAnyRemote)
        XCTAssertEqual(s.probeFailures, [])
    }

    func testBareRepo() async throws {
        let fx = try GitFixture()
        let (_, origin) = try fx.makeRepoWithOrigin("r")
        let s = try await fx.inspector().inspect(origin)
        XCTAssertEqual(s.kind, .bare)
        XCTAssertNil(s.workingTree)
        XCTAssertNil(s.topLevel)
        guard case .branch(let n, _)? = s.head else { return XCTFail("\(String(describing: s.head))") }
        XCTAssertEqual(n, "main")
        XCTAssertEqual(s.probeFailures, [])
    }

    func testSubmodule() async throws {
        let fx = try GitFixture()
        let sub = try fx.makeRepo("subsrc")
        let parent = try fx.makeRepo("parent")
        try fx.git(["submodule", "add", "-q", sub.path, "sub"], in: parent)
        try fx.git(["commit", "-q", "-m", "add sub"], in: parent)
        let insp = fx.inspector()
        let s = try await insp.inspect(parent.appendingPathComponent("sub"))
        XCTAssertEqual(s.kind, .submodule)
        try fx.write(parent.appendingPathComponent("sub"), "dirty.txt")
        let p = try await insp.inspect(parent)
        XCTAssertEqual(p.workingTree?.submodulesDirty, 1)
        XCTAssertEqual(p.workingTree?.isClean, false)
    }

    func testDefaultBranchFallbackOrder() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.git(["branch", "-m", "master"], in: repo)
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.defaultBranch, .init(ref: "refs/heads/master", source: .fallback))
        XCTAssertEqual(s.isMergedIntoDefault, true)
        let none = try fx.makeRepo("r2")
        try fx.git(["branch", "-m", "trunk"], in: none)
        let n = try await fx.inspector().inspect(none)
        XCTAssertNil(n.defaultBranch)
        XCTAssertNil(n.isMergedIntoDefault)
        XCTAssertEqual(n.probeFailures, [])
    }

    func testOperationInProgress() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.git(["checkout", "-q", "-b", "other"], in: repo)
        try fx.commit(repo, file: "README.md", msg: "o", content: "other\n")
        try fx.git(["checkout", "-q", "main"], in: repo)
        try fx.commit(repo, file: "README.md", msg: "m", content: "main\n")
        try fx.git(["merge", "other"], in: repo, allowFail: true)
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.operationInProgress, .merge)
        XCTAssertGreaterThanOrEqual(s.workingTree?.conflicted ?? 0, 1)
    }

    func testIndexLockDoesNotBreakStatus() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        FileManager.default.createFile(atPath: repo.path + "/.git/index.lock", contents: Data())
        let s = try await fx.inspector().inspect(repo)
        XCTAssertTrue(s.indexLockPresent)
        XCTAssertNotNil(s.workingTree)
        XCTAssertEqual(s.probeFailures, [])
    }

    func testUnicodeAndNewlinePaths() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        let wt = fx.root.appendingPathComponent("wt é\n x")
        try fx.addWorktree(repo, wt, branch: "uni")
        try fx.write(wt, "ünï cödé.txt")
        let insp = fx.inspector()
        let s = try await insp.inspect(wt)
        XCTAssertEqual(s.kind, .linkedWorktree)
        XCTAssertEqual(s.topLevel, wt.path)
        XCTAssertEqual(s.workingTree?.untracked, 1)
        let list = try await insp.listWorktrees(of: repo)
        XCTAssertTrue(list.contains { $0.path == wt.path })
    }

    // MARK: read-only proof

    private func snapshot(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(atPath: root.path)!
        for case let rel as String in e {
            var st = stat()
            guard lstat(root.path + "/" + rel, &st) == 0 else { continue }
            out[rel] = "\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(st.st_ino)"
        }
        return out
    }

    func testInspectIsReadOnly() async throws {
        let fx = try GitFixture()
        let (repo, origin) = try fx.makeRepoWithOrigin("r")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addWorktree(repo, wt, branch: "feat")
        try fx.write(wt, "README.md", "dirty\n")
        try fx.write(wt, "untracked.txt")
        let sub = try fx.makeRepo("subsrc")
        try fx.git(["submodule", "add", "-q", sub.path, "sub"], in: repo)
        let unborn = try fx.makeRepo("unborn", commit: false)
        let insp = fx.inspector()
        // Warm up once so lazy one-time state exists, then compare.
        let targets = [repo, wt, origin, unborn, repo.appendingPathComponent("sub")]
        let before = try snapshot(fx.root)
        for t in targets { _ = try await insp.inspect(t) }
        _ = try await insp.listWorktrees(of: repo)
        let after = try snapshot(fx.root)
        XCTAssertEqual(before, after)
    }

    // MARK: fake git

    func testStatusTimeoutIsPartialFailure() async throws {
        let fx = try GitFixture()
        let fake = try fx.script("fakegit", "case \" $* \" in *\" status \"*) sleep 30; exit 0;; esac\nexec \(fx.gitURL.path) \"$@\"")
        let repo = try fx.makeRepo("r")
        let insp = fx.inspector(gitExecutable: fake) { $0.statusTimeout = .milliseconds(500) }
        let start = ContinuousClock.now
        let s = try await insp.inspect(repo)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        XCTAssertNil(s.workingTree)
        XCTAssertTrue(s.probeFailures.contains { $0.probe == .status && $0.kind == .timedOut })
        XCTAssertNotNil(s.hasRemotes)
        XCTAssertNotNil(s.stash)
    }

    func testCancellationPropagates() async throws {
        let fx = try GitFixture()
        let pidFile = fx.root.appendingPathComponent("pid").path
        let fake = try fx.script(
            "fakegit",
            "case \" $* \" in *\" status \"*) echo $$ > \(pidFile); sleep 30; exit 0;; esac\nexec \(fx.gitURL.path) \"$@\"")
        let repo = try fx.makeRepo("r")
        let insp = fx.inspector(gitExecutable: fake)
        let task = Task { try await insp.inspect(repo) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile) {
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let pid = pid_t(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        var gone = false
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { gone = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(gone, "child still alive")
    }

    func testConcurrencyLimit() async throws {
        let fx = try GitFixture()
        let log = fx.root.appendingPathComponent("log").path
        let fake = try fx.script(
            "fakegit",
            "echo S >> \(log); sleep 0.05; \(fx.gitURL.path) \"$@\"; rc=$?; echo E >> \(log); exit $rc")
        var repos: [URL] = []
        for i in 0..<4 { repos.append(try fx.makeRepo("r\(i)")) }
        let insp = fx.inspector(gitExecutable: fake) { $0.maxConcurrentProcesses = 2 }
        try await withThrowingTaskGroup(of: Void.self) { g in
            for r in repos { g.addTask { _ = try await insp.inspect(r) } }
            try await g.waitForAll()
        }
        var cur = 0, peak = 0
        for l in try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n") {
            cur += l == "S" ? 1 : -1
            peak = max(peak, cur)
        }
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertGreaterThan(peak, 0)
    }
}
