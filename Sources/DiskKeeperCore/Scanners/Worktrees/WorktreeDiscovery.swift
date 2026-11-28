import Darwin
import Foundation

/// A problem worth showing next to the list; never fatal.
public enum InventoryWarning: Sendable, Hashable {
    case orcaUnavailable(String)
    case repositoryFailed(path: String, reason: String)
    case prLookupFailed(repository: String, reason: String)
    case processTableUnreadable
}

public struct DiscoveryResult: Sendable {
    public var worktrees: [DiscoveredWorktree]
    public var warnings: [InventoryWarning]
}

/// Finds worktrees from Orca, from `git worktree list` of every known repository, and from the usual worktree
/// folders. Deduped by realpath; main checkouts and bare repositories are kept as context, never as candidates.
/// It only lists directories and reads `.git` files; it never follows symlinks.
public struct WorktreeDiscovery: Sendable {
    public struct Configuration: Sendable {
        public var home: String
        /// Absolute (already expanded) roots to scan for repositories, depth <= `maxDepth`.
        public var projectRoots: [String]
        /// `<home>`-relative parents whose grandchildren are worktrees, e.g. `orca/workspaces` -> `<home>/orca/workspaces/*/*`.
        public var workspaceParents: [String]
        /// Per-repository folders (relative to the repository) whose children are worktrees.
        public var inRepoFolders: [String]
        public var maxDepth = 3

        public init(home: String, projectRoots: [String], workspaceParents: [String]? = nil, inRepoFolders: [String]? = nil) {
            self.home = home
            self.projectRoots = projectRoots
            self.workspaceParents = workspaceParents ?? ["orca/workspaces", "conductor/workspaces", ".codex/worktrees"]
            self.inRepoFolders = inRepoFolders ?? [".claude/worktrees", ".worktrees"]
        }
    }

    static let skippedNames: Set<String> = ["node_modules", ".build", "DerivedData", "Pods", "target", "vendor", "venv", ".venv"]
    static let skippedUnderHome: Set<String> = ["Library", "Pictures", "Music", "Movies", "Applications", "Desktop", "Documents", "Downloads", "Public"]

    private let config: Configuration
    private let git: GitInspector

    public init(configuration: Configuration, git: GitInspector) {
        self.config = configuration
        self.git = git
    }

    public func discover(orca: OrcaListResult) async -> DiscoveryResult {
        var warnings: [InventoryWarning] = []
        if let w = orca.warning { warnings.append(.orcaUnavailable(w)) }
        var found: [String: DiscoveredWorktree] = [:]
        var repos: [String: String] = [:]   // realpath -> path to run git in
        func add(_ w: DiscoveredWorktree) {
            guard let key = Self.canonical(w.path) else { return }
            var w = w
            w.path = key
            if var old = found[key] {
                old.sources.formUnion(w.sources)
                old.orca = old.orca ?? w.orca
                old.gitEntry = old.gitEntry ?? w.gitEntry
                old.isMain = old.isMain || w.isMain
                old.isBare = old.isBare || w.isBare
                old.isOrphan = old.isOrphan || w.isOrphan
                old.repoPath = old.repoPath ?? w.repoPath
                old.branch = old.branch ?? w.branch
                old.head = old.head ?? w.head
                found[key] = old
            } else {
                found[key] = w
            }
        }
        func addRepo(_ path: String?) {
            guard let path, let key = Self.canonical(path) else { return }
            repos[key] = key
        }

        // (a) Orca rows
        for row in orca.rows {
            guard let key = Self.canonical(row.path) else { continue }
            var w = DiscoveredWorktree(path: key, branch: row.branch, head: row.head, isMain: row.isMain, isBare: row.isBare,
                                       sources: [.orca], orca: row)
            if row.isMain || row.isBare {
                w.repoPath = key
                addRepo(key)
            } else if let l = linked(key) {
                w.repoPath = l.repoPath
                w.isOrphan = l.orphan
                addRepo(l.repoPath)
            }
            add(w)
        }
        // (b) project roots, (c) workspace and in-repo folders
        for dir in scanRoots() {
            switch classify(dir) {
            case .mainRepo: addRepo(dir)
            case .linked(let l):
                add(DiscoveredWorktree(path: dir, repoPath: l.repoPath, isOrphan: l.orphan, sources: [.root]))
                addRepo(l.repoPath)
            case .none: break
            }
        }
        for repo in Array(repos.keys) {
            for folder in config.inRepoFolders {
                for child in Self.childDirectories(repo + "/" + folder) {
                    if case .linked(let l) = classify(child) {
                        add(DiscoveredWorktree(path: child, repoPath: l.repoPath, isOrphan: l.orphan, sources: [.root]))
                        addRepo(l.repoPath)
                    }
                }
            }
        }
        // (d) every known repository: `git worktree list`
        for repo in repos.keys.sorted() {
            do {
                let entries = try await git.listWorktrees(of: URL(fileURLWithPath: repo))
                for e in entries {
                    guard e.path.hasPrefix("/") else { continue }
                    var w = DiscoveredWorktree(
                        path: e.path, repoPath: repo, branch: e.branch.map(Self.shortBranch), head: e.head, isMain: e.isMain,
                        isBare: e.isBare, sources: [.git], gitEntry: e)
                    if !FileManager.default.fileExists(atPath: e.path) { w.isOrphan = !e.isMain }   // registered but gone
                    add(w)
                }
            } catch is CancellationError {
                break
            } catch {
                warnings.append(.repositoryFailed(path: repo, reason: "\(error)"))
            }
        }
        // Rows we only know from Orca/roots must know their repo; main checkouts point at themselves.
        for (k, var w) in found {
            if w.isMain || w.isBare { w.repoPath = w.repoPath ?? k }
            found[k] = w
        }
        return DiscoveryResult(worktrees: found.values.sorted { $0.path < $1.path }, warnings: warnings)
    }

    // MARK: - Filesystem helpers

    enum Classification {
        case mainRepo
        case linked(Linked)
        case none
    }
    struct Linked {
        var repoPath: String?
        var orphan: Bool
    }

    func classify(_ dir: String) -> Classification {
        var st = stat()
        guard lstat(dir + "/.git", &st) == 0 else { return .none }
        if (st.st_mode & S_IFMT) == S_IFDIR { return .mainRepo }
        guard (st.st_mode & S_IFMT) == S_IFREG, let l = linked(dir) else { return .none }
        return .linked(l)
    }

    /// A linked worktree (`.git` file with a worktrees gitdir). Submodules and malformed files are not worktrees.
    func linked(_ dir: String) -> Linked? {
        guard let info = GitInspector.readGitFile(in: URL(fileURLWithPath: dir)) else { return nil }
        var common = info.commonDir
        if common == nil, let r = info.gitdir.range(of: "/.git/worktrees/") { common = String(info.gitdir[..<r.lowerBound]) + "/.git" }
        if common == nil && info.gitdir.contains("/.git/modules/") { return nil }   // submodule
        guard info.gitdirExists || common != nil else { return nil }
        var repo: String?
        if let c = common {
            let main = (c as NSString).lastPathComponent == ".git" ? (c as NSString).deletingLastPathComponent : c
            repo = main.isEmpty ? nil : Self.real(main)
        }
        return Linked(repoPath: repo, orphan: !info.gitdirExists)
    }

    /// Directories to classify: project roots to `maxDepth`, plus `<home>/<parent>/*/*`.
    func scanRoots() -> [String] {
        var out: [String] = []
        let home = Self.real(config.home)
        for root in config.projectRoots {
            let r = Self.real(root)
            walk(r, depth: 0, isHome: r == home, into: &out)
        }
        for parent in config.workspaceParents {
            for a in Self.childDirectories(home + "/" + parent) {
                out.append(a)
                out.append(contentsOf: Self.childDirectories(a))
            }
        }
        return out
    }

    private func walk(_ dir: String, depth: Int, isHome: Bool, into out: inout [String]) {
        guard depth <= config.maxDepth else { return }
        if depth > 0 || !isHome {
            if case .none = classify(dir) {} else { out.append(dir); return }
        }
        guard depth < config.maxDepth else { return }
        for child in Self.childDirectories(dir) {
            let name = (child as NSString).lastPathComponent
            if Self.skippedNames.contains(name) { continue }
            if isHome && depth == 0 && Self.skippedUnderHome.contains(name) { continue }
            walk(child, depth: depth + 1, isHome: isHome, into: &out)
        }
    }

    /// Child directories (not symlinks, not hidden), sorted. Unreadable directories yield nothing.
    static func childDirectories(_ dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return path
        }
    }

    static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return real(path)
    }

    static func real(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    static func shortBranch(_ ref: String) -> String { ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref }
}
