import Darwin
import XCTest

@testable import DiskKeeperCore

/// Regression tests from the independent PR #36 verification (adversarial repos and runner abuse).
final class GitHardeningTests: XCTestCase {
    private func cleanPushedRepo(_ fx: GitFixture) throws -> URL {
        let (repo, _) = try fx.makeRepoWithOrigin("r")
        return repo
    }

    // F1: ignored-but-precious files
    func testIgnoredPreciousFilesAreReported() async throws {
        let fx = try GitFixture()
        let repo = try cleanPushedRepo(fx)
        try fx.commit(repo, file: ".gitignore", msg: "ign", content: ".env\n*.pem\ndata/\nnode_modules/\n")
        try fx.push(repo, "main")
        try fx.write(repo, ".env", "SECRET=1\n")
        try fx.write(repo, "server.pem", "-----BEGIN-----\n")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("data"), withIntermediateDirectories: true)
        try fx.write(repo.appendingPathComponent("data"), "irreplaceable.db")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.workingTree?.isClean, true)
        let ig = try XCTUnwrap(s.ignored)
        XCTAssertEqual(Set(ig.preciousPaths), [".env", "server.pem", "data/", "data/irreplaceable.db"])
        XCTAssertEqual(ig.count, 4)
        XCTAssertEqual(ig.unclassifiedPaths, [])
    }

    func testOnlyRegenerableIgnoredIsNotPrecious() async throws {
        let fx = try GitFixture()
        let repo = try cleanPushedRepo(fx)
        try fx.commit(repo, file: ".gitignore", msg: "ign", content: "node_modules/\nbuild/\n")
        for d in ["node_modules", "build"] {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(d), withIntermediateDirectories: true)
            try fx.write(repo.appendingPathComponent(d), "x")
        }
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.ignored?.preciousPaths, [])
        XCTAssertEqual(s.ignored?.unclassifiedPaths, [])
        XCTAssertEqual(s.ignored?.count, 2)
    }

    func testUnknownIgnoredIsUnclassified() async throws {
        let fx = try GitFixture()
        let repo = try cleanPushedRepo(fx)
        try fx.commit(repo, file: ".gitignore", msg: "ign", content: "notes.txt\n")
        try fx.write(repo, "notes.txt")
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.ignored?.unclassifiedPaths, ["notes.txt"])
    }

    // F2: assume-unchanged / skip-worktree hide edits
    func testAssumeUnchangedAndSkipWorktreeEditsAreDetected() async throws {
        let fx = try GitFixture()
        let repo = try cleanPushedRepo(fx)
        try fx.commit(repo, file: "a.txt", msg: "a")
        try fx.commit(repo, file: "b.txt", msg: "b")
        try fx.commit(repo, file: "c.txt", msg: "c")
        try fx.push(repo, "main")
        try fx.git(["update-index", "--assume-unchanged", "a.txt"], in: repo)
        try fx.git(["update-index", "--skip-worktree", "b.txt"], in: repo)
        let before = try await fx.inspector().inspect(repo)
        XCTAssertEqual(before.hiddenFromStatus, .init(assumeUnchanged: 1, skipWorktree: 1, modified: 0, unverified: 0))
        try fx.write(repo, "a.txt", "LOCAL EDIT a\n")
        try fx.write(repo, "b.txt", "LOCAL EDIT b\n")
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.workingTree?.unstaged, 0)  // status is blind...
        XCTAssertEqual(s.hiddenFromStatus?.total, 2)
        XCTAssertEqual(s.hiddenFromStatus?.modified, 2)  // ...the inspector is not
    }

    // F4: filter drivers must not execute
    func testHostileRepoConfigDoesNotExecute() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.commit(repo, file: "f.txt", msg: "f", content: "hello\n")
        try fx.commit(repo, file: ".gitattributes", msg: "attr", content: "* filter=evil diff=evil\n")
        let m = fx.root.path + "/pwned"
        let cfg = """
            [core]
            \tfsmonitor = /usr/bin/touch \(m)-fsmonitor
            \thooksPath = \(fx.root.path)/hooks
            \tpager = /usr/bin/touch \(m)-pager
            [filter "evil"]
            \tclean = /usr/bin/touch \(m)-clean; cat
            \tsmudge = cat
            [diff "evil"]
            \ttextconv = /usr/bin/touch \(m)-textconv; cat
            [diff]
            \texternal = /usr/bin/touch \(m)-diffext
            [gpg]
            \tprogram = /usr/bin/touch \(m)-gpg
            [log]
            \tshowSignature = true
            """
        let cfgPath = repo.path + "/.git/config"
        let old = try String(contentsOfFile: cfgPath, encoding: .utf8)
        try (old + "\n" + cfg + "\n").write(toFile: cfgPath, atomically: true, encoding: .utf8)
        let hooks = try fx.tmp.dir("hooks")
        for h in ["post-index-change", "pre-commit", "reference-transaction", "post-checkout"] {
            let p = hooks.path + "/" + h
            try "#!/bin/sh\n/usr/bin/touch \(m)-hook-\(h)\n".write(toFile: p, atomically: true, encoding: .utf8)
            chmod(p, 0o755)
        }
        try fx.tmp.setMTime("r/f.txt", Date().addingTimeInterval(-3600))
        try fx.tmp.setMTime("r/.gitattributes", Date().addingTimeInterval(-3600))
        _ = try await fx.inspector().inspect(repo)
        let pwned = try FileManager.default.contentsOfDirectory(atPath: fx.root.path).filter { $0.hasPrefix("pwned") }
        XCTAssertEqual(pwned, [], "commands executed")
    }

    func testHostileProcessFilterDoesNotExecute() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.commit(repo, file: "f.txt", msg: "f", content: "hello\n")
        try fx.commit(repo, file: ".gitattributes", msg: "attr", content: "* filter=evil\n")
        let m = fx.root.path + "/pwned-process"
        let cfgPath = repo.path + "/.git/config"
        let old = try String(contentsOfFile: cfgPath, encoding: .utf8)
        try (old + "\n[filter \"evil\"]\n\tprocess = /usr/bin/touch \(m)\n").write(
            toFile: cfgPath, atomically: true, encoding: .utf8)
        try fx.tmp.setMTime("r/f.txt", Date().addingTimeInterval(-3600))
        _ = try await fx.inspector().inspect(repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: m))
    }

    func testFilterNameParsingAndArguments() {
        let d = Data("filter.lfs.clean\0filter.lfs.smudge\0filter.a.b.process\0filter.broken\0".utf8)
        XCTAssertEqual(GitPorcelain.parseFilterNames(d), ["lfs", "a.b"])
        let env = GitPorcelain.filterNeutralizingEnvironment(["x=y"])
        XCTAssertEqual(env["GIT_CONFIG_COUNT"], "4")
        XCTAssertEqual(Set(env.filter { $0.key.hasPrefix("GIT_CONFIG_KEY_") }.values),
                       ["filter.x=y.clean", "filter.x=y.smudge", "filter.x=y.process", "filter.x=y.required"])
        XCTAssertEqual(GitPorcelain.parseFilterNames(Data("filter.x=y.process\0".utf8)), ["x=y"])
    }

    // R1: a filter name containing '=' must still be neutralized
    func testFilterNameContainingEqualsDoesNotExecute() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.commit(repo, file: "f.txt", msg: "f", content: "hello\n")
        try fx.commit(repo, file: ".gitattributes", msg: "attr", content: "* filter=x=y\n")
        let m = fx.root.path + "/pwned-eq"
        let cfgPath = repo.path + "/.git/config"
        let old = try String(contentsOfFile: cfgPath, encoding: .utf8)
        try (old + "\n[filter \"x=y\"]\n\tprocess = /usr/bin/touch \(m)\n\tclean = /usr/bin/touch \(m)-clean\n").write(
            toFile: cfgPath, atomically: true, encoding: .utf8)
        try fx.tmp.setMTime("r/f.txt", Date().addingTimeInterval(-3600))
        _ = try await fx.inspector().inspect(repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: m))
        XCTAssertFalse(FileManager.default.fileExists(atPath: m + "-clean"))
    }

    // R2 + N1: secrets inside ignored "regenerable" dirs, any case
    func testPreciousFilesInsideIgnoredRegenerableDirsAreReported() async throws {
        let fx = try GitFixture()
        let repo = try cleanPushedRepo(fx)
        try fx.commit(repo, file: ".gitignore", msg: "ign", content: "node_modules/\ndist/\nbuild/\nout/\n.venv/\n.ENVRC\n.ENV\n")
        for f in ["node_modules/pkg/.env", "dist/prod.pem", "build/id_ed25519", "out/customers.sqlite", ".venv/.env", "dist/Server.PEM"] {
            let u = repo.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fx.write(repo, f)
        }
        try fx.write(repo, ".ENV")
        try fx.write(repo, "dist/harmless.js")
        let s = try await fx.inspector().inspect(repo)
        let precious = Set(try XCTUnwrap(s.ignored).preciousPaths)
        for f in ["node_modules/pkg/.env", "dist/prod.pem", "build/id_ed25519", "out/customers.sqlite", ".venv/.env", "dist/Server.PEM", ".ENV"] {
            XCTAssertTrue(precious.contains(f), "missing \(f) in \(precious)")
        }
        XCTAssertFalse(precious.contains("dist/harmless.js"))
        XCTAssertEqual(s.ignored?.unclassifiedPaths, [])
    }

    func testAnySubmoduleUnpushedOrDirty() {
        let clean = GitState(
            path: "/s", kind: .submodule, gitDir: "/g", commonDir: "/g",
            commitsNotOnAnyRemote: .init(value: 0, isCapped: false), workingTree: .init())
        var unpushed = clean
        unpushed.commitsNotOnAnyRemote = .init(value: 1, isCapped: false)
        var top = GitState(path: "/t", kind: .mainWorktree, gitDir: "/g", commonDir: "/g", submodules: [clean])
        XCTAssertFalse(top.anySubmoduleUnpushedOrDirty)
        var mid = clean
        mid.submodules = [unpushed]
        top.submodules = [mid]
        XCTAssertTrue(top.anySubmoduleUnpushedOrDirty)
    }

    // F6: core.worktree redirect
    func testCoreWorktreeRedirectIsFlagged() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.write(repo, "dirty-untracked.txt")
        let other = try fx.tmp.dir("elsewhere")
        try fx.git(["config", "core.worktree", other.path], in: repo)
        let s = try await fx.inspector().inspect(repo)
        XCTAssertTrue(s.topLevelMismatch)
        XCTAssertTrue(s.probeFailures.contains { $0.probe == .status })
    }

    func testSquashMergeReadsUnmerged() async throws {
        let fx = try GitFixture()
        let (repo, _) = try fx.makeRepoWithOrigin("r")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addWorktree(repo, wt, branch: "feat")
        try fx.commit(wt, file: "x.txt", msg: "x")
        try fx.git(["merge", "--squash", "feat"], in: repo)
        try fx.git(["commit", "-q", "-m", "squash"], in: repo)
        try fx.push(repo, "main")
        let s = try await fx.inspector().inspect(wt)
        XCTAssertEqual(s.isMergedIntoDefault, false)
        XCTAssertEqual(s.commitsNotOnAnyRemote?.value, 1)
    }

    // F3: a commit that exists only inside a submodule
    func testUnpushedCommitInsideSubmodule() async throws {
        let fx = try GitFixture()
        let subOrigin = try fx.makeBareRemote("sub-origin.git")
        let subsrc = try fx.makeRepo("subsrc")
        try fx.addRemote(subsrc, subOrigin)
        try fx.push(subsrc, "main", setUpstream: true)
        let (repo, _) = try fx.makeRepoWithOrigin("sup")
        try fx.git(["submodule", "add", "-q", subOrigin.path, "sub"], in: repo)
        try fx.git(["commit", "-q", "-m", "add sub"], in: repo)
        try fx.push(repo, "main")
        let sub = repo.appendingPathComponent("sub")
        try fx.commit(sub, file: "local-only.txt", msg: "never pushed")
        try fx.git(["add", "sub"], in: repo)
        try fx.git(["commit", "-q", "-m", "bump sub"], in: repo)
        try fx.push(repo, "main")
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.submodules?.count, 1)
        XCTAssertEqual(s.submodules?.first?.commitsNotOnAnyRemote, .init(value: 1, isCapped: false))
        XCTAssertEqual(s.submodules?.first?.kind, .submodule)
    }

    func testCleanPushedSubmoduleIsClean() async throws {
        let fx = try GitFixture()
        let subOrigin = try fx.makeBareRemote("sub-origin.git")
        let subsrc = try fx.makeRepo("subsrc")
        try fx.addRemote(subsrc, subOrigin)
        try fx.push(subsrc, "main", setUpstream: true)
        let (repo, _) = try fx.makeRepoWithOrigin("sup")
        try fx.git(["submodule", "add", "-q", subOrigin.path, "sub"], in: repo)
        try fx.git(["commit", "-q", "-m", "add sub"], in: repo)
        try fx.push(repo, "main")
        let s = try await fx.inspector().inspect(repo)
        XCTAssertEqual(s.submodules?.first?.commitsNotOnAnyRemote?.value, 0)
        XCTAssertEqual(s.workingTree?.isClean, true)
        XCTAssertEqual(s.probeFailures, [])
    }

    func testShallowClone() async throws {
        let fx = try GitFixture()
        let (repo, origin) = try fx.makeRepoWithOrigin("r")
        for i in 0..<3 { try fx.commit(repo, file: "f\(i)", msg: "c\(i)") }
        try fx.push(repo, "main")
        let clone = fx.root.appendingPathComponent("shallow")
        try fx.git(["clone", "-q", "--depth", "1", "file://" + origin.path, clone.path], in: fx.root)
        try fx.commit(clone, file: "mine", msg: "mine")
        let s = try await fx.inspector().inspect(clone)
        XCTAssertEqual(s.isShallow, true)
        XCTAssertEqual(s.commitsNotOnAnyRemote?.value, 1)
    }

    // F7: bare repo stash
    func testBareRepoStash() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        try fx.write(repo, "README.md", "dirty\n")
        try fx.git(["stash", "-q"], in: repo)
        let bare = fx.root.appendingPathComponent("bare.git")
        try fx.git(["clone", "-q", "--mirror", repo.path, bare.path], in: fx.root)
        let s = try await fx.inspector().inspect(bare)
        XCTAssertEqual(s.kind, .bare)
        XCTAssertGreaterThanOrEqual(s.stash?.total ?? 0, 1)
    }

    func testWeirdMainRepoPaths() async throws {
        let fx = try GitFixture()
        for name in ["sp ace", "nl\nline", "é-ü 日本", "-dash", "trail\n"] {
            let repo = try fx.makeRepo(name)
            try fx.write(repo, "u.txt")
            let s = try await fx.inspector().inspect(repo)
            XCTAssertEqual(s.workingTree?.untracked, 1, name.debugDescription)
            XCTAssertEqual(s.gitDir, repo.path + "/.git")
            XCTAssertFalse(s.topLevelMismatch)
        }
    }

    func testStashFromDetached() async throws {
        let fx = try GitFixture()
        let repo = try fx.makeRepo("r")
        let wt = fx.root.appendingPathComponent("wt")
        try fx.addDetachedWorktree(repo, wt)
        try fx.write(wt, "README.md", "dirty\n")
        try fx.git(["stash", "-q"], in: wt)
        let s = try await fx.inspector().inspect(wt)
        XCTAssertEqual(s.stash?.total, 1)
        XCTAssertEqual(s.stash?.mentioningBranch, 0)
    }

    func testInspectNonGitDirAndMissing() async throws {
        let fx = try GitFixture()
        let d = try fx.tmp.dir("plain")
        do { _ = try await fx.inspector().inspect(d); XCTFail() } catch let e as GitInspectorError {
            XCTAssertEqual(e, .notARepository(d.path))
        }
        let missing = fx.root.appendingPathComponent("nope")
        do { _ = try await fx.inspector().inspect(missing); XCTFail() } catch let e as GitInspectorError {
            XCTAssertEqual(e, .pathNotFound(missing.path))
        }
    }

    func testLargeRepoStatusTimeout() async throws {
        guard ProcessInfo.processInfo.environment["VERIFY_LARGE"] != nil else { throw XCTSkip("set VERIFY_LARGE=1") }
        let fx = try GitFixture()
        let repo = try fx.makeRepo("big")
        for i in 0..<200 {
            let d = repo.appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for j in 0..<250 { FileManager.default.createFile(atPath: d.path + "/f\(j)", contents: Data("\(i)-\(j)".utf8)) }
        }
        try fx.git(["add", "-A"], in: repo)
        try fx.git(["commit", "-q", "-m", "big"], in: repo)
        let s = try await fx.inspector { $0.statusTimeout = .milliseconds(30) }.inspect(repo)
        XCTAssertNil(s.workingTree)
    }

    // F8: a cancelled first call must not cache "no excludes"
    func testCancelledFirstCallDoesNotPoisonExcludes() async throws {
        let fx = try GitFixture()
        let ign = fx.root.appendingPathComponent("ign")
        try "junk\n".write(to: ign, atomically: true, encoding: .utf8)
        try "[core]\n\texcludesFile = \(ign.path)\n".write(toFile: fx.home + "/.gitconfig", atomically: true, encoding: .utf8)
        let repo = try fx.makeRepo("r")
        try fx.write(repo, "junk")
        let insp = fx.inspector()
        let t = Task { try await insp.inspect(repo) }
        t.cancel()
        _ = try? await t.value
        let s = try await insp.inspect(repo)
        XCTAssertEqual(s.workingTree?.untracked, 0)
    }
}

final class ProcessRunnerHardeningTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/")

    // F5: a descendant that escaped the process group must not pin `run` past the timeout
    func testEscapedGrandchildDoesNotExtendTimeout() async throws {
        let r = ProcessRunner(killGrace: .milliseconds(200))
        let script = "use POSIX; my $p=fork(); if($p==0){POSIX::setsid(); exec('/bin/sleep','6');} print \"x\\n\"; sleep 30;"
        let start = ContinuousClock.now
        do {
            _ = try await r.run(
                executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", script],
                environment: ["PATH": "/usr/bin:/bin"], currentDirectory: root, timeout: .milliseconds(500))
            XCTFail("expected timeout")
        } catch let e as ProcessRunnerError {
            guard case .timedOut = e else { return XCTFail("\(e)") }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500 + 200 + 500 + 300))
    }

    // F9: a timeout that fires before/at spawn is a timeout, never a cancellation
    func testZeroTimeoutIsNeverCancellation() async throws {
        let r = ProcessRunner(killGrace: .milliseconds(100))
        for _ in 0..<30 {
            do {
                _ = try await r.run(
                    executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], environment: [:],
                    currentDirectory: root, timeout: .zero)
            } catch is CancellationError {
                XCTFail("timeout reported as cancellation")
            } catch is ProcessRunnerError {
            }
        }
    }

    func testNoZombiesAfterManyTimeouts() async throws {
        let r = ProcessRunner(killGrace: .milliseconds(100))
        for _ in 0..<20 {
            _ = try? await r.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 5"],
                environment: [:], currentDirectory: root, timeout: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(500))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "ps -A -o ppid=,stat=,comm= | awk '$1==\(getpid()) && $2 ~ /Z/'"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "", "zombies")
    }

    func testStderrFloodCapped() async throws {
        let r = ProcessRunner(maxOutputBytes: 1 << 16)
        let res = try await r.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 5000000 /dev/zero >&2; echo ok"],
            environment: [:], currentDirectory: root, timeout: .seconds(10))
        XCTAssertTrue(res.stderrTruncated)
        XCTAssertEqual(res.stderr.count, 1 << 16)
        XCTAssertEqual(res.stdoutString, "ok\n")
    }
}
