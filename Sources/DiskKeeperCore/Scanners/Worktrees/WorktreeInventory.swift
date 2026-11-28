import Darwin
import Foundation

public struct WorktreeRow: Sendable, Hashable, Identifiable {
    public var facts: WorktreeFacts
    public var verdict: SafeCleanVerdict
    public init(facts: WorktreeFacts, verdict: SafeCleanVerdict) {
        self.facts = facts
        self.verdict = verdict
    }
    public var id: String { facts.worktree.path }
    public var path: String { facts.worktree.path }
    public var name: String { facts.worktree.name }
    public var repoName: String { facts.worktree.repoPath.map { ($0 as NSString).lastPathComponent } ?? "-" }
}

public struct InventoryResult: Sendable {
    /// Candidates: linked worktrees and orphans.
    public var rows: [WorktreeRow]
    /// Main checkouts and bare repositories, shown as context only.
    public var contexts: [DiscoveredWorktree]
    public var warnings: [InventoryWarning]
    public var generatedAt: Date
    public init(rows: [WorktreeRow] = [], contexts: [DiscoveredWorktree] = [], warnings: [InventoryWarning] = [], generatedAt: Date = Date()) {
        self.rows = rows
        self.contexts = contexts
        self.warnings = warnings
        self.generatedAt = generatedAt
    }
    public var safeRows: [WorktreeRow] { rows.filter { $0.verdict.eligible } }
}

/// Read-only worktree inventory. It does not go through `ScanEngine`: it gathers facts, then `WorktreeClassifier`
/// decides. Nothing is removed, pruned, locked or fetched.
public actor WorktreeInventory {
    public struct Dependencies: Sendable {
        public var git: GitInspector
        public var orca: any OrcaWorktreeListing
        public var prSource: any PRStatusSource
        public var processes: any ProcessTableReading
        public var sizer: FileSizer
        public var protectedPaths: ProtectedPaths?
        public var home: String
        public var projectRoots: [String]
        /// cwd's of this app (and its ancestors) that must never be removed.
        public var ownCWDs: [String]
        public var workspaceParents: [String]?
        public var inRepoFolders: [String]?
        public var maxConcurrent = 4

        public init(git: GitInspector, orca: any OrcaWorktreeListing, prSource: any PRStatusSource = DisabledPRStatusSource(),
                    processes: any ProcessTableReading, sizer: FileSizer = FileSizer(), protectedPaths: ProtectedPaths?, home: String,
                    projectRoots: [String], ownCWDs: [String] = [FileManager.default.currentDirectoryPath],
                    workspaceParents: [String]? = nil, inRepoFolders: [String]? = nil) {
            self.git = git
            self.orca = orca
            self.prSource = prSource
            self.processes = processes
            self.sizer = sizer
            self.protectedPaths = protectedPaths
            self.home = home
            self.projectRoots = projectRoots
            self.ownCWDs = ownCWDs
            self.workspaceParents = workspaceParents
            self.inRepoFolders = inRepoFolders
        }
    }

    private let deps: Dependencies
    private let now: @Sendable () -> Date
    private var last: InventoryResult?

    public init(dependencies: Dependencies, now: @escaping @Sendable () -> Date = { Date() }) {
        self.deps = dependencies
        self.now = now
    }

    public var latest: InventoryResult? { last }

    public func refresh(settings: AppSettings) async -> InventoryResult {
        let orca = await deps.orca.list()
        let discovery = WorktreeDiscovery(
            configuration: .init(home: deps.home, projectRoots: deps.projectRoots, workspaceParents: deps.workspaceParents,
                                 inRepoFolders: deps.inRepoFolders),
            git: deps.git)
        let found = await discovery.discover(orca: orca)
        var warnings = found.warnings
        let table = deps.processes.snapshot()
        if table == nil { warnings.append(.processTableUnreadable) }

        let candidates = found.worktrees.filter(\.isCandidate)
        let contexts = found.worktrees.filter { !$0.isCandidate }
        let prs = await prLookups(for: candidates, settings: settings, warnings: &warnings)
        let t = now()
        let ownCWDs = deps.ownCWDs.map(WorktreeDiscovery.real)

        var rows: [WorktreeRow] = []
        await withTaskGroup(of: WorktreeRow?.self) { group in
            var iterator = candidates.makeIterator()
            func next() -> DiscoveredWorktree? { iterator.next() }
            var inFlight = 0
            while inFlight < deps.maxConcurrent, let w = next() {
                group.addTask { await self.row(for: w, table: table, prs: prs, ownCWDs: ownCWDs, settings: settings, now: t) }
                inFlight += 1
            }
            for await r in group {
                if let r { rows.append(r) }
                if let w = next() {
                    group.addTask { await self.row(for: w, table: table, prs: prs, ownCWDs: ownCWDs, settings: settings, now: t) }
                }
            }
        }
        rows.sort { ($0.facts.worktree.repoPath ?? "", $0.path) < ($1.facts.worktree.repoPath ?? "", $1.path) }
        let result = InventoryResult(rows: rows, contexts: contexts, warnings: warnings, generatedAt: t)
        last = result
        return result
    }

    // MARK: - Pull requests

    private func prLookups(for candidates: [DiscoveredWorktree], settings: AppSettings, warnings: inout [InventoryWarning]) async -> [String: PRLookup] {
        guard settings.useGitHubCLIForPRs else { return [:] }
        var out: [String: PRLookup] = [:]
        for repo in Set(candidates.compactMap(\.repoPath)).sorted() {
            guard !Task.isCancelled else { break }
            let remote = try? await deps.git.originURL(in: URL(fileURLWithPath: repo))
            let lookup = await deps.prSource.lookup(repository: repo, remoteURL: remote)
            if case .unavailable(let why) = lookup { warnings.append(.prLookupFailed(repository: repo, reason: why)) }
            out[repo] = lookup
        }
        return out
    }

    // MARK: - One worktree

    private func row(for w: DiscoveredWorktree, table: ProcessTableSnapshot?, prs: [String: PRLookup], ownCWDs: [String],
                     settings: AppSettings, now: Date) async -> WorktreeRow {
        var facts = WorktreeFacts(worktree: w)
        let url = URL(fileURLWithPath: w.path)
        facts.pathAllowed = deps.protectedPaths.map { $0.check(w.path).isAllowed }
        facts.containsOwnCWD = ownCWDs.contains { Self.isInside($0, root: w.path) }
        facts.processes = table.map { Self.processes(in: w.path, table: $0) }

        var newest: Date?
        if !w.isOrphan || FileManager.default.fileExists(atPath: w.path) {
            if let report = try? await deps.sizer.size(of: url) {
                facts.allocatedBytes = report.allocatedBytes
                newest = report.newestModification
            }
        }
        if !w.isOrphan {
            await gather(into: &facts, url: url, prs: prs, settings: settings)
        } else {
            facts.gitError = "git directory is missing"
        }
        facts.lastActivity = Self.activity(for: w, newestFileChange: newest)
        return WorktreeRow(facts: facts, verdict: WorktreeClassifier.verdict(facts, now: now, settings: settings))
    }

    private func gather(into facts: inout WorktreeFacts, url: URL, prs: [String: PRLookup], settings: AppSettings) async {
        let git = deps.git
        let state: GitState
        do {
            state = try await git.inspect(url)
        } catch is CancellationError {
            return
        } catch {
            facts.gitError = "\(error)"
            return
        }
        facts.git = state
        if let base = state.defaultBranch?.ref, state.head != nil {
            facts.baseRef = base
            facts.cherryAllApplied = (try? await git.cherryAllApplied(base: base, in: url)) ?? nil
            facts.mergeTreeMatchesBase = (try? await git.mergeTreeMatchesBase(base: base, in: url)) ?? nil
        }
        if case .detached = state.head { facts.commitsNotOnAnyRef = (try? await git.commitsNotOnAnyRef(in: url)) ?? nil }

        guard settings.useGitHubCLIForPRs else { facts.pr = .disabled; return }
        guard let repo = facts.worktree.repoPath, let lookup = prs[repo] else { facts.pr = .unknown(reason: "no lookup"); return }
        switch lookup {
        case .unavailable(let why): facts.pr = .unknown(reason: why)
        case .records(let records):
            var branch: String?
            if case .branch(let name, _) = state.head { branch = name }
            facts.pr = PRMatcher.state(branch: branch, records: records)
            if case .merged(_, let oid, _) = facts.pr {
                facts.headCoveredByMergedPR = Self.isHex(oid) ? ((try? await git.isAncestor("HEAD", of: oid, in: url)) ?? nil) : nil
            }
        }
    }

    // MARK: - Helpers

    static func isInside(_ path: String, root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    static func isHex(_ s: String) -> Bool { s.count >= 7 && s.count <= 64 && s.allSatisfy(\.isHexDigit) }

    static func processes(in root: String, table: ProcessTableSnapshot) -> [WorktreeProcess] {
        table.records.compactMap { r in
            guard let cwd = r.cwd, isInside(cwd, root: root) else { return nil }
            return WorktreeProcess(pid: r.pid, name: r.name, agent: AgentClassifier.agent(of: r, ancestors: table.ancestors(of: r.pid)))
        }
        .sorted { $0.pid < $1.pid }
    }

    /// D7: max(Orca activity, mtime of the git `index`, `logs/HEAD`, `HEAD`, newest file change from sizing).
    static func activity(for w: DiscoveredWorktree, newestFileChange: Date?) -> WorktreeActivity? {
        var best: WorktreeActivity?
        func offer(_ d: Date?, _ s: ActivitySource) {
            guard let d else { return }
            if best == nil || d > best!.date { best = WorktreeActivity(date: d, source: s) }
        }
        offer(w.orca?.lastActivityAt, .orca)
        if let info = GitInspector.readGitFile(in: URL(fileURLWithPath: w.path)), info.gitdirExists {
            offer(mtime(info.gitdir + "/index"), .index)
            offer(mtime(info.gitdir + "/logs/HEAD"), .headLog)
            offer(mtime(info.gitdir + "/HEAD"), .head)
        }
        offer(newestFileChange, .files)
        return best
    }

    static func mtime(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }
}
