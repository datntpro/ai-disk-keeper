import Darwin
import Foundation

/// Read-only, timeout-bounded, cancellable wrapper around the git CLI. Reports facts as `GitState`;
/// never classifies. Pass worktree roots (a subdirectory of a worktree is `notARepository`).
public final class GitInspector: Sendable {
    public struct Configuration: Sendable, Hashable {
        public var gitExecutable: URL?
        /// Injected so tests never touch the real home.
        public var homeDirectory: String
        public var defaultTimeout: Duration = .seconds(10)
        public var statusTimeout: Duration = .seconds(60)
        public var maxConcurrentProcesses: Int = 4
        public var revListCap: Int = 10_000
        /// Test hook: no version check, no excludes lookup and no base arguments (for fake "git").
        var rawMode = false

        public init(homeDirectory: String, gitExecutable: URL? = nil) {
            self.homeDirectory = homeDirectory
            self.gitExecutable = gitExecutable
        }
    }

    struct Prepared: Sendable {
        var git: URL
        var excludesFile: String?
    }

    actor InspectorState {
        var prepared: Prepared?
        func store(_ p: Prepared) { prepared = p }
    }

    /// Per-repository `-c filter.<name>.*=` neutralizers, applied to every git call of one inspection.
    @TaskLocal static var extraConfigArgs: [String] = []
    static let maxSubmoduleDepth = 3
    static let hiddenFileCheckCap = 500

    private let configuration: Configuration
    private let runner: ProcessRunner
    private let state = InspectorState()
    private let limiter: AsyncLimiter

    public init(configuration: Configuration, runner: ProcessRunner = ProcessRunner()) {
        self.configuration = configuration
        self.runner = runner
        self.limiter = AsyncLimiter(limit: configuration.maxConcurrentProcesses)
    }

    // MARK: - Locating git

    /// Never falls back to `/usr/bin/git` (an xcrun shim that can pop up the CLT installer).
    public static func locateGit(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        developerDir: () -> String? = GitInspector.selectedDeveloperDir
    ) -> URL? {
        #if DEBUG
        if let o = environment["AIDK_GIT"], o.hasPrefix("/"), fileExists(o) { return URL(fileURLWithPath: o) }
        #endif
        if let d = developerDir() {
            let p = d + "/usr/bin/git"
            if fileExists(p) { return URL(fileURLWithPath: p) }
        }
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileExists(p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// Reads xcode-select's symlink without spawning anything.
    public static func selectedDeveloperDir() -> String? {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = readlink("/var/db/xcode_select_link", &buf, buf.count - 1)
        if n > 0 { return String(cString: buf) }
        if FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") {
            return "/Library/Developer/CommandLineTools"
        }
        if FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git") {
            return "/Applications/Xcode.app/Contents/Developer"
        }
        return nil
    }

    // MARK: - Environment and arguments

    static func makeEnvironment(home: String, ceiling: String? = nil) -> [String: String] {
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "LC_ALL": "C", "LANG": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
            "GIT_PAGER": "cat", "PAGER": "cat",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_ADVICE": "0",
        ]
        if let ceiling { env["GIT_CEILING_DIRECTORIES"] = ceiling }
        return env
    }

    static func baseArguments(excludesFile: String?) -> [String] {
        var a = [
            "--no-pager",
            "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
            "-c", "core.untrackedCache=false", "-c", "log.showSignature=false",
            "-c", "color.ui=false", "-c", "core.quotePath=false", "-c", "protocol.allow=never",
            "-c", "diff.external=", "-c", "status.submoduleSummary=false",
            "-c", "gc.auto=0", "-c", "maintenance.auto=false",
        ]
        if let excludesFile { a += ["-c", "core.excludesFile=\(excludesFile)"] }
        return a
    }

    static func realpathString(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    private static func realpathOfParent(_ path: URL) -> String {
        let parent = path.deletingLastPathComponent().path
        guard let r = realpath(parent, nil) else { return parent }
        defer { free(r) }
        return String(cString: r)
    }

    // MARK: - Process plumbing

    private func prepare() async throws -> Prepared {
        if let p = await state.prepared { return p }
        let git: URL
        if let g = configuration.gitExecutable {
            git = g
        } else if let g = Self.locateGit() {
            git = g
        } else {
            throw GitInspectorError.gitUnavailable
        }
        var excludes: String?
        var cacheable = true
        if !configuration.rawMode {
            let root = URL(fileURLWithPath: "/")
            let env = Self.makeEnvironment(home: configuration.homeDirectory)
            var envNoLock = env
            envNoLock["GIT_CONFIG_NOSYSTEM"] = nil
            envNoLock["GIT_CONFIG_GLOBAL"] = nil
            let excludesEnv = envNoLock
            let r: ProcessResult
            do {
                r = try await limited {
                    try await self.runner.run(
                        executable: git, arguments: ["version"], environment: env,
                        currentDirectory: root, timeout: self.configuration.defaultTimeout)
                }
            } catch is ProcessRunnerError {
                throw GitInspectorError.gitUnavailable
            }
            guard r.exitStatus == 0, let v = GitPorcelain.parseGitVersion(r.stdoutString) else {
                throw GitInspectorError.gitUnavailable
            }
            guard GitPorcelain.isVersionSupported(v) else {
                throw GitInspectorError.gitTooOld(found: "\(v.major).\(v.minor).\(v.patch)")
            }
            // Re-inject only the user's global excludes file (global config is otherwise disabled).
            do {
                let c = try await limited {
                    try await self.runner.run(
                        executable: git, arguments: ["config", "--global", "--get", "core.excludesFile"],
                        environment: excludesEnv, currentDirectory: root, timeout: self.configuration.defaultTimeout)
                }
                if c.exitStatus == 0 {
                    var p = c.stdoutString.trimmingCharacters(in: .newlines)
                    if p.hasPrefix("~/") { p = configuration.homeDirectory + "/" + p.dropFirst(2) }
                    if p.hasPrefix("/"), FileManager.default.fileExists(atPath: p) { excludes = p }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                cacheable = false  // timeout/launch failure: use no excludes now, but retry next time
            }
        }
        let p = Prepared(git: git, excludesFile: excludes)
        if cacheable { await state.store(p) }
        return p
    }

    private func limited<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await limiter.acquire()
        do {
            let v = try await body()
            await limiter.release()
            return v
        } catch {
            await limiter.release()
            throw error
        }
    }

    /// Runs git with the hardened env/args. Throws `ProcessRunnerError`, `CancellationError` or `GitInspectorError`.
    func runGit(_ args: [String], in path: URL, timeout: Duration? = nil) async throws -> ProcessResult {
        let prep = try await prepare()
        let argv = configuration.rawMode
            ? args : Self.baseArguments(excludesFile: prep.excludesFile) + Self.extraConfigArgs + ["-C", path.path] + args
        let env = Self.makeEnvironment(
            home: configuration.homeDirectory, ceiling: Self.realpathOfParent(path))
        let t = timeout ?? configuration.defaultTimeout
        let cwd = configuration.rawMode ? path : URL(fileURLWithPath: "/")
        do {
            return try await limited {
                try await self.runner.run(
                    executable: prep.git, arguments: argv, environment: env,
                    currentDirectory: cwd, timeout: t)
            }
        } catch ProcessRunnerError.launchFailed {
            throw GitInspectorError.gitUnavailable
        }
    }

    private struct ProbeOut<T: Sendable>: Sendable {
        var value: T?
        var failure: GitProbeFailure?
    }

    /// Runs one probe; maps timeout / failure into a `GitProbeFailure`. Only `CancellationError` escapes.
    private func probe(
        _ p: GitProbe, _ args: [String], in path: URL, timeout: Duration? = nil,
        okStatuses: Set<Int32> = [0]
    ) async throws -> (ProcessResult?, GitProbeFailure?) {
        do {
            let r = try await runGit(args, in: path, timeout: timeout)
            if okStatuses.contains(r.exitStatus) { return (r, nil) }
            return (r, GitProbeFailure(probe: p, kind: .failed, message: Self.message(r)))
        } catch is CancellationError {
            throw CancellationError()
        } catch ProcessRunnerError.timedOut(_, let after) {
            return (nil, GitProbeFailure(probe: p, kind: .timedOut, message: "timed out after \(after)"))
        } catch {
            return (nil, GitProbeFailure(probe: p, kind: .failed, message: "\(error)"))
        }
    }

    private static func message(_ r: ProcessResult) -> String {
        let s = r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return "exit \(r.exitStatus): " + String(s.prefix(500))
    }

    private static func firstLine(_ r: ProcessResult) -> String {
        var s = r.stdoutString
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    // MARK: - Public API

    /// Inspect a worktree root (main or linked), a submodule root or a bare repo directory.
    public func inspect(_ path: URL) async throws -> GitState {
        try await inspect(path, depth: 0)
    }

    func inspect(_ path: URL, depth: Int) async throws -> GitState {
        try Task.checkCancellation()
        var st = stat()
        guard lstat(path.path, &st) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw GitInspectorError.pathNotFound(path.path) }
            throw GitInspectorError.gitFailed("lstat \(path.path): \(String(cString: strerror(errno)))")
        }
        // Follow a symlink to a directory the way git will.
        var isDir = (st.st_mode & S_IFMT) == S_IFDIR
        if (st.st_mode & S_IFMT) == S_IFLNK, stat(path.path, &st) == 0 { isDir = (st.st_mode & S_IFMT) == S_IFDIR }
        guard isDir else { throw GitInspectorError.notADirectory(path.path) }
        _ = try await prepare()

        // Discovery
        let dirR: ProcessResult
        do {
            dirR = try await runGit(["rev-parse", "--path-format=absolute", "--git-dir"], in: path)
        } catch ProcessRunnerError.timedOut {
            throw GitInspectorError.timedOut(.discovery)
        }
        guard dirR.exitStatus == 0 else {
            let err = dirR.stderrString
            if err.contains("dubious ownership") { throw GitInspectorError.unsafeRepository(path.path) }
            if err.contains("not a git repository") {
                if let info = Self.readGitFile(in: path), !info.gitdirExists {
                    throw GitInspectorError.orphanedWorktree(gitdir: info.gitdir)
                }
                throw GitInspectorError.notARepository(path.path)
            }
            throw GitInspectorError.gitFailed(Self.message(dirR))
        }
        let gitDir = Self.firstLine(dirR)
        async let commonR = discoveryCall(["rev-parse", "--path-format=absolute", "--git-common-dir"], path)
        async let flagsR = discoveryCall(
            ["rev-parse", "--is-bare-repository", "--is-shallow-repository", "--show-superproject-working-tree"],
            path)
        let common = try await commonR
        let flags = try await flagsR
        guard let disc = GitPorcelain.parseDiscovery(flags.stdoutString) else {
            throw GitInspectorError.gitFailed("unparseable rev-parse output")
        }
        let commonDir = Self.firstLine(common)
        let kind: GitState.Kind =
            disc.isBare ? .bare
            : disc.superproject != nil ? .submodule
            : (URL(fileURLWithPath: gitDir).standardized.path == URL(fileURLWithPath: commonDir).standardized.path
                ? .mainWorktree : .linkedWorktree)
        var topLevel: String?
        if !disc.isBare {
            let t = try await discoveryCall(["rev-parse", "--path-format=absolute", "--show-toplevel"], path)
            topLevel = Self.firstLine(t)
        }

        // Neutralize repo-local filter drivers (clean/smudge/process could execute during status).
        var filterNames: [String] = []
        var failures: [GitProbeFailure] = []
        let (fr, ff) = try await probe(
            .filters, ["config", "-z", "--name-only", "--get-regexp", "^filter\\."], in: path,
            okStatuses: [0, 1])
        if let fr, ff == nil { filterNames = GitPorcelain.parseFilterNames(fr.stdout) } else if let ff { failures.append(ff) }
        let filterArgs = GitPorcelain.filterNeutralizingArguments(filterNames)
        if ff != nil {
            // Cannot enumerate drivers: refuse to run anything that could execute one.
            throw GitInspectorError.gitFailed("cannot enumerate filter drivers: \(ff!.message)")
        }
        return try await Self.$extraConfigArgs.withValue(filterArgs) {
            try await self.finishInspect(
                path, depth: depth, gitDir: gitDir, commonDir: commonDir, kind: kind, topLevel: topLevel,
                disc: disc, failures: failures)
        }
    }

    private func finishInspect(
        _ path: URL, depth: Int, gitDir: String, commonDir: String, kind: GitState.Kind, topLevel: String?,
        disc: GitPorcelain.Discovery, failures initialFailures: [GitProbeFailure]
    ) async throws -> GitState {
        var failures = initialFailures
        let isBare = disc.isBare

        async let statusP = statusProbe(path, skip: isBare)
        async let bareHeadP = bareHeadProbe(path, skip: !isBare)
        async let stashP = stashProbe(path, skip: isBare)
        async let remotesP = remotesProbe(path)
        async let defaultP = defaultBranchProbe(path)
        async let lastP = lastCommitProbe(path)
        async let indexP = indexProbe(path, skip: isBare)
        async let ignoredP = ignoredProbe(path, skip: isBare)

        let status = try await statusP
        let bareHead = try await bareHeadP
        let stashRecords = try await stashP
        let remotes = try await remotesP
        let defaultB = try await defaultP
        let last = try await lastP
        let index = try await indexP
        let ignoredR = try await ignoredP
        failures += [index.failure, ignoredR.failure].compactMap { $0 }
        failures += [status.failure, bareHead.failure, stashRecords.failure, remotes.failure, defaultB.failure, last.failure]
            .compactMap { $0 }
        if let s = status.value, s.workingTree.isLowerBound {
            failures.append(GitProbeFailure(probe: .status, kind: .outputTruncated, message: "status output truncated"))
        }

        // Head / upstream / working tree
        var head: GitState.Head? = bareHead.value
        var upstream: GitState.Upstream?
        var workingTree: GitState.WorkingTree?
        var branchName: String?
        if let s = status.value {
            workingTree = s.workingTree
            if let name = s.headName {
                if s.oid == "(initial)" {
                    head = .unborn(branch: name)
                } else if name == "(detached)", let oid = s.oid {
                    head = .detached(oid: oid)
                } else if let oid = s.oid {
                    head = .branch(name: name, oid: oid)
                }
            }
            if let u = s.upstream {
                upstream = (s.ahead != nil && s.behind != nil)
                    ? .tracking(ref: u, ahead: s.ahead!, behind: s.behind!) : .gone(ref: u)
            } else {
                upstream = GitState.Upstream.none
            }
        } else if isBare {
            upstream = GitState.Upstream.none
        }
        switch head {
        case .branch(let n, _)?, .unborn(let n)?: branchName = n
        default: break
        }
        var stash: GitState.Stash?
        if let recs = stashRecords.value { stash = GitPorcelain.stashSummary(recs, branch: branchName) }

        // Dependent probes
        var isUnbornOrUnknown = true
        switch head {
        case .branch?, .detached?: isUnbornOrUnknown = false
        default: break
        }
        var merged: Bool?
        var notOnRemote: GitState.Count?
        if !isUnbornOrUnknown {
            async let mergedP = mergedProbe(path, defaultRef: defaultB.value ?? nil, skip: isBare)
            async let notOnP = notOnRemoteProbe(path)
            let m = try await mergedP
            let n = try await notOnP
            merged = m.value
            notOnRemote = n.value
            failures += [m.failure, n.failure].compactMap { $0 }
        }

        // Hidden edits (assume-unchanged / skip-worktree)
        var hidden: GitState.HiddenFromStatus?
        if let entries = index.value {
            let h = try await hiddenProbe(path, entries: entries)
            hidden = h.value
            if let f = h.failure { failures.append(f) }
        }

        // Submodules: recurse (unpushed commits and dirty state inside them)
        var subStates: [GitState]?
        if let entries = index.value, !isBare {
            var subs: [GitState] = []
            var dirtyPaths = Set(status.value?.dirtySubmodulePaths ?? [])
            for e in entries where e.isGitlink {
                let sub = path.appendingPathComponent(e.path, isDirectory: true)
                guard FileManager.default.fileExists(atPath: sub.path + "/.git") else { continue }  // not initialized
                guard depth < Self.maxSubmoduleDepth else {
                    failures.append(.init(probe: .submodules, kind: .failed, message: "\(e.path): nesting too deep"))
                    continue
                }
                do {
                    let st = try await inspect(sub, depth: depth + 1)
                    subs.append(st)
                    if st.workingTree?.isClean != true { dirtyPaths.insert(e.path) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(.init(probe: .submodules, kind: .failed, message: "\(e.path): \(error)"))
                    dirtyPaths.insert(e.path)
                }
            }
            subStates = subs
            workingTree?.submodulesDirty = dirtyPaths.count
        }

        // Does status describe this directory? (core.worktree redirect, not a root)
        var mismatch = false
        if let topLevel, Self.realpathString(topLevel) != Self.realpathString(path.path) {
            mismatch = true
            failures.append(.init(
                probe: .status, kind: .failed, message: "worktree is elsewhere: top level is \(topLevel)"))
        }

        // Filesystem-only facts
        let fm = FileManager.default
        var lock: GitState.WorktreeLock?
        let lockPath = gitDir + "/locked"
        if fm.fileExists(atPath: lockPath) {
            let text = (try? String(contentsOfFile: lockPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lock = .init(reason: (text?.isEmpty ?? true) ? nil : text)
        }
        let op: GitState.Operation? =
            fm.fileExists(atPath: gitDir + "/MERGE_HEAD") ? .merge
            : (fm.fileExists(atPath: gitDir + "/rebase-merge") || fm.fileExists(atPath: gitDir + "/rebase-apply")) ? .rebase
            : fm.fileExists(atPath: gitDir + "/CHERRY_PICK_HEAD") ? .cherryPick
            : fm.fileExists(atPath: gitDir + "/REVERT_HEAD") ? .revert
            : fm.fileExists(atPath: gitDir + "/BISECT_LOG") ? .bisect : nil

        try Task.checkCancellation()
        return GitState(
            path: path.path, kind: kind, topLevel: topLevel, gitDir: gitDir, commonDir: commonDir,
            head: head, upstream: upstream, hasRemotes: remotes.value,
            commitsNotOnAnyRemote: notOnRemote, workingTree: workingTree, stash: stash,
            defaultBranch: defaultB.value ?? nil, isMergedIntoDefault: merged, lastCommit: last.value ?? nil,
            operationInProgress: op, indexLockPresent: fm.fileExists(atPath: gitDir + "/index.lock"),
            worktreeLock: lock, isShallow: disc.isShallow, probeFailures: failures,
            ignored: ignoredR.value, hiddenFromStatus: hidden, submodules: subStates, topLevelMismatch: mismatch)
    }

    private func discoveryCall(_ args: [String], _ path: URL) async throws -> ProcessResult {
        let r: ProcessResult
        do {
            r = try await runGit(args, in: path)
        } catch ProcessRunnerError.timedOut {
            throw GitInspectorError.timedOut(.discovery)
        }
        guard r.exitStatus == 0 else { throw GitInspectorError.gitFailed(Self.message(r)) }
        return r
    }

    /// `git worktree list --porcelain -z` run in `repository` (any worktree, or the bare dir).
    public func listWorktrees(of repository: URL) async throws -> [GitWorktreeEntry] {
        let r: ProcessResult
        do {
            r = try await runGit(["worktree", "list", "--porcelain", "-z"], in: repository)
        } catch ProcessRunnerError.timedOut {
            throw GitInspectorError.timedOut(.worktreeList)
        }
        guard r.exitStatus == 0 else {
            if r.stderrString.contains("not a git repository") {
                throw GitInspectorError.notARepository(repository.path)
            }
            throw GitInspectorError.gitFailed(Self.message(r))
        }
        return GitPorcelain.parseWorktreeList(r.stdout)
    }

    /// Pure FS read of `<dir>/.git` when it is a FILE ("gitdir: <path>"). nil if there is no such file.
    public static func readGitFile(in directory: URL) -> GitFileInfo? {
        let file = directory.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
            let text = try? String(contentsOf: file, encoding: .utf8),
            let line = text.components(separatedBy: "\n").first, line.hasPrefix("gitdir:")
        else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let gitdir = (raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw) : URL(fileURLWithPath: raw, relativeTo: directory)).standardized
        var common: String?
        if let c = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8) {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                common = (t.hasPrefix("/")
                    ? URL(fileURLWithPath: t) : URL(fileURLWithPath: t, relativeTo: gitdir)).standardized.path
            }
        }
        return GitFileInfo(
            gitdir: gitdir.path, gitdirExists: FileManager.default.fileExists(atPath: gitdir.path), commonDir: common)
    }

    // MARK: - Probes

    private func statusProbe(_ path: URL, skip: Bool) async throws -> ProbeOut<GitPorcelain.StatusResult> {
        if skip { return .init() }
        let (r, f) = try await probe(
            .status,
            ["status", "--porcelain=v2", "--branch", "--show-stash", "-z", "--untracked-files=normal",
             "--no-renames", "--ignore-submodules=dirty"],
            in: path, timeout: configuration.statusTimeout)
        guard let r, f == nil else { return .init(failure: f) }
        return .init(value: GitPorcelain.parseStatus(r.stdout, truncated: r.stdoutTruncated))
    }

    private func bareHeadProbe(_ path: URL, skip: Bool) async throws -> ProbeOut<GitState.Head> {
        if skip { return .init() }
        let (sym, _) = try await probe(.status, ["symbolic-ref", "-q", "HEAD"], in: path, okStatuses: [0, 1])
        let (oidR, f) = try await probe(.status, ["rev-parse", "-q", "--verify", "HEAD"], in: path, okStatuses: [0, 1])
        guard let sym, let oidR else { return .init(failure: f) }
        let ref = Self.firstLine(sym)
        let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        if sym.exitStatus == 0 {
            if oidR.exitStatus == 0 { return .init(value: .branch(name: branch, oid: Self.firstLine(oidR))) }
            return .init(value: .unborn(branch: branch))
        }
        if oidR.exitStatus == 0 { return .init(value: .detached(oid: Self.firstLine(oidR))) }
        return .init(failure: f)
    }

    private func stashProbe(_ path: URL, skip isBare: Bool) async throws -> ProbeOut<[GitPorcelain.StashRecord]> {
        if isBare {
            // `git stash` needs a work tree; read refs/stash and its reflog directly.
            let (ref, f0) = try await probe(
                .stash, ["for-each-ref", "--count=1", "--format=%(refname)", "refs/stash"], in: path)
            guard let ref, f0 == nil else { return .init(failure: f0) }
            if ref.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .init(value: []) }
            let (r, f) = try await probe(
                .stash, ["log", "-g", "-z", "--format=%gd%x1f%ct%x1f%gs", "refs/stash"], in: path)
            guard let r, f == nil else { return .init(failure: f) }
            var recs = GitPorcelain.parseStashList(r.stdout)
            var failure: GitProbeFailure?
            if recs.isEmpty {  // mirror clones copy refs/stash without its reflog
                recs = [.init(ref: "refs/stash", date: nil, subject: "")]
                failure = .init(probe: .stash, kind: .failed, message: "stash reflog missing; count is a lower bound")
            }
            return .init(value: recs, failure: failure)
        }
        let (r, f) = try await probe(
            .stash, ["stash", "list", "-z", "--format=%gd%x1f%ct%x1f%gs"], in: path)
        guard let r, f == nil else { return .init(failure: f) }
        return .init(value: GitPorcelain.parseStashList(r.stdout))
    }

    private func remotesProbe(_ path: URL) async throws -> ProbeOut<Bool> {
        let (r, f) = try await probe(
            .remotes, ["for-each-ref", "--count=1", "--format=%(refname)", "refs/remotes"], in: path)
        guard let r, f == nil else { return .init(failure: f) }
        return .init(value: !r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func defaultBranchProbe(_ path: URL) async throws -> ProbeOut<GitState.DefaultBranch?> {
        let (sym, f1) = try await probe(
            .defaultBranch, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], in: path, okStatuses: [0, 1])
        guard let sym else { return .init(failure: f1) }
        if sym.exitStatus == 0 {
            let ref = Self.firstLine(sym)
            if !ref.isEmpty { return .init(value: .some(.init(ref: ref, source: .originHEAD))) }
        }
        let candidates = ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        let (r, f2) = try await probe(
            .defaultBranch, ["for-each-ref", "--format=%(refname)"] + candidates, in: path)
        guard let r, f2 == nil else { return .init(failure: f2) }
        let existing = Set(r.stdoutString.split(separator: "\n").map(String.init))
        if let first = candidates.first(where: existing.contains) {
            return .init(value: .some(.init(ref: first, source: .fallback)))
        }
        return .init(value: .some(nil))
    }

    private func lastCommitProbe(_ path: URL) async throws -> ProbeOut<GitState.LastCommit?> {
        let (r, f) = try await probe(
            .lastCommit, ["log", "-1", "--no-show-signature", "--format=%H%x1f%ct%x1f%s", "HEAD"],
            in: path, okStatuses: [0, 128])
        guard let r, f == nil else { return .init(failure: f) }
        if r.exitStatus == 128 { return .init(value: .some(nil)) }  // unborn: not a failure
        let p = Self.firstLine(r).split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
        guard p.count == 3, let ts = TimeInterval(p[1]) else { return .init(value: .some(nil)) }
        return .init(value: .some(.init(oid: String(p[0]), date: Date(timeIntervalSince1970: ts), subject: String(p[2]))))
    }

    private func mergedProbe(_ path: URL, defaultRef: GitState.DefaultBranch?, skip: Bool) async throws -> ProbeOut<Bool> {
        guard !skip, let defaultRef else { return .init() }
        let (r, f) = try await probe(
            .merged, ["merge-base", "--is-ancestor", "HEAD", defaultRef.ref], in: path, okStatuses: [0, 1])
        guard let r, f == nil else { return .init(failure: f) }
        return .init(value: r.exitStatus == 0)
    }

    private func notOnRemoteProbe(_ path: URL) async throws -> ProbeOut<GitState.Count> {
        let cap = configuration.revListCap
        let (r, f) = try await probe(
            .notOnRemote,
            ["rev-list", "--count", "--max-count=\(cap + 1)", "HEAD", "--not", "--remotes"], in: path)
        guard let r, f == nil, let n = Int(Self.firstLine(r)) else { return .init(failure: f) }
        return .init(value: n > cap ? .init(value: cap, isCapped: true) : .init(value: n, isCapped: false))
    }

    private func indexProbe(_ path: URL, skip: Bool) async throws -> ProbeOut<[GitPorcelain.IndexEntry]> {
        if skip { return .init() }
        let (r, f) = try await probe(.hiddenFiles, ["ls-files", "-s", "-v", "-z"], in: path)
        guard let r, f == nil else { return .init(failure: f) }
        var failure: GitProbeFailure?
        if r.stdoutTruncated {
            failure = .init(probe: .hiddenFiles, kind: .outputTruncated, message: "index listing truncated")
        }
        return .init(value: GitPorcelain.parseIndexEntries(r.stdout, truncated: r.stdoutTruncated), failure: failure)
    }

    private func ignoredProbe(_ path: URL, skip: Bool) async throws -> ProbeOut<GitState.IgnoredSummary> {
        if skip { return .init() }
        let (r, f) = try await probe(
            .ignored, ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], in: path)
        guard let r, f == nil else { return .init(failure: f) }
        var names = GitPorcelain.splitNUL(r.stdout)
        if r.stdoutTruncated, !names.isEmpty { names.removeLast() }
        let c = GitPorcelain.classifyIgnored(names)
        return .init(
            value: .init(
                count: names.count, isLowerBound: r.stdoutTruncated, preciousPaths: c.precious,
                unclassifiedPaths: c.unclassified),
            failure: r.stdoutTruncated
                ? .init(probe: .ignored, kind: .outputTruncated, message: "ignored listing truncated") : nil)
    }

    /// Counts assume-unchanged / skip-worktree entries and compares their on-disk content with the index.
    private func hiddenProbe(_ path: URL, entries: [GitPorcelain.IndexEntry]) async throws -> ProbeOut<GitState.HiddenFromStatus> {
        var h = GitState.HiddenFromStatus()
        let hidden = entries.filter { !$0.isGitlink && ($0.isAssumeUnchanged || $0.isSkipWorktree) }
        h.assumeUnchanged = hidden.filter(\.isAssumeUnchanged).count
        h.skipWorktree = hidden.filter { !$0.isAssumeUnchanged && $0.isSkipWorktree }.count
        var failure: GitProbeFailure?
        var toHash: [GitPorcelain.IndexEntry] = []
        for (i, e) in hidden.enumerated() {
            if i >= Self.hiddenFileCheckCap { h.unverified += 1; continue }
            var st = stat()
            guard lstat(path.path + "/" + e.path, &st) == 0 else { continue }  // absent (sparse checkout)
            if (st.st_mode & S_IFMT) == S_IFREG { toHash.append(e) } else { h.modified += 1 }
        }
        var i = 0
        while i < toHash.count {
            let batch = Array(toHash[i..<min(i + 100, toHash.count)])
            i += 100
            let (r, f) = try await probe(
                .hiddenFiles, ["hash-object", "--no-filters", "--"] + batch.map(\.path), in: path)
            guard let r, f == nil else {
                h.unverified += batch.count
                failure = f
                continue
            }
            let shas = r.stdoutString.split(separator: "\n").map(String.init)
            if shas.count != batch.count {
                h.unverified += batch.count
                continue
            }
            h.modified += zip(shas, batch).filter { $0 != $1.sha }.count
        }
        return .init(value: h, failure: failure)
    }
}
