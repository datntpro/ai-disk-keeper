import Foundation

/// How a worktree was found. A worktree can have several.
public enum WorktreeSource: String, Sendable, Hashable, Codable, CaseIterable { case orca, git, root }

/// What Orca says about a worktree. Hints only: Orca's PR cache was stale in practice, so none of it proves "merged".
public struct OrcaWorktreeRow: Sendable, Hashable, Codable {
    public var instanceID: String?
    public var path: String
    public var repoID: String?
    public var branch: String?
    public var head: String?
    public var isMain: Bool
    public var isBare: Bool
    public var displayName: String?
    public var lastActivityAt: Date?
    /// `linkedPR` number when Orca has one.
    public var linkedPR: Int?
    public var workspaceStatus: String?

    public init(
        instanceID: String? = nil, path: String, repoID: String? = nil, branch: String? = nil, head: String? = nil,
        isMain: Bool = false, isBare: Bool = false, displayName: String? = nil, lastActivityAt: Date? = nil,
        linkedPR: Int? = nil, workspaceStatus: String? = nil
    ) {
        self.instanceID = instanceID
        self.path = path
        self.repoID = repoID
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isBare = isBare
        self.displayName = displayName
        self.lastActivityAt = lastActivityAt
        self.linkedPR = linkedPR
        self.workspaceStatus = workspaceStatus
    }
}

/// One worktree (or main checkout, listed as context) found by discovery. Paths are realpaths.
public struct DiscoveredWorktree: Sendable, Hashable {
    public var path: String
    /// The main checkout (or bare repository) this worktree belongs to; nil when it can't be determined (orphan).
    public var repoPath: String?
    public var branch: String?
    public var head: String?
    public var isMain: Bool
    public var isBare: Bool
    /// `.git` points at a missing git directory.
    public var isOrphan: Bool
    public var sources: Set<WorktreeSource>
    public var orca: OrcaWorktreeRow?
    public var gitEntry: GitWorktreeEntry?

    public var name: String { (path as NSString).lastPathComponent }
    public var isCandidate: Bool { !isMain && !isBare }

    public init(
        path: String, repoPath: String? = nil, branch: String? = nil, head: String? = nil, isMain: Bool = false,
        isBare: Bool = false, isOrphan: Bool = false, sources: Set<WorktreeSource> = [], orca: OrcaWorktreeRow? = nil,
        gitEntry: GitWorktreeEntry? = nil
    ) {
        self.path = path
        self.repoPath = repoPath
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isBare = isBare
        self.isOrphan = isOrphan
        self.sources = sources
        self.orca = orca
        self.gitEntry = gitEntry
    }
}

/// What the pull request source knows about a branch.
public enum PRState: Sendable, Hashable {
    case merged(number: Int, headOID: String, url: String?)
    case closed(number: Int, url: String?)
    case open(number: Int, url: String?)
    /// A successful lookup found no pull request for the branch.
    case none
    /// Lookup failed or the branch could not be matched.
    case unknown(reason: String)
    /// The opt-in `gh` lookup is off.
    case disabled

    public var number: Int? {
        switch self {
        case .merged(let n, _, _), .closed(let n, _), .open(let n, _): n
        default: nil
        }
    }
}

public struct WorktreeProcess: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var agent: AgentKind?
    public init(pid: Int32, name: String, agent: AgentKind?) {
        self.pid = pid
        self.name = name
        self.agent = agent
    }
}

public enum ActivitySource: String, Sendable, Hashable, Codable {
    case orca, index, headLog, head, files
}

public struct WorktreeActivity: Sendable, Hashable {
    public var date: Date
    public var source: ActivitySource
    public init(date: Date, source: ActivitySource) {
        self.date = date
        self.source = source
    }
}

/// Everything the classifier reads about one worktree. `nil` means "not determined" and fails closed.
public struct WorktreeFacts: Sendable, Hashable {
    public var worktree: DiscoveredWorktree
    public var git: GitState?
    public var gitError: String?
    public var allocatedBytes: Int64?
    /// Output of `GitInspector.cherryAllApplied` against `baseRef`.
    public var cherryAllApplied: Bool?
    public var mergeTreeMatchesBase: Bool?
    /// Commits only a detached HEAD holds.
    public var commitsNotOnAnyRef: Int?
    /// Local base used for the proofs, e.g. `refs/remotes/origin/main`.
    public var baseRef: String?
    public var pr: PRState
    /// HEAD equals or is an ancestor of a merged PR's head commit. nil = not determined.
    public var headCoveredByMergedPR: Bool?
    /// nil = the process table was unreadable.
    public var processes: [WorktreeProcess]?
    /// Open files from T20, when merged. nil = not checked.
    public var openFileHolders: Int?
    public var lastActivity: WorktreeActivity?
    /// The app's own cwd (or an ancestor of it) is inside this worktree.
    public var containsOwnCWD: Bool
    /// `ProtectedPaths` verdict; nil = no policy was supplied (fail closed).
    public var pathAllowed: Bool?

    public init(
        worktree: DiscoveredWorktree, git: GitState? = nil, gitError: String? = nil, allocatedBytes: Int64? = nil,
        cherryAllApplied: Bool? = nil, mergeTreeMatchesBase: Bool? = nil, commitsNotOnAnyRef: Int? = nil,
        baseRef: String? = nil, pr: PRState = .disabled, headCoveredByMergedPR: Bool? = nil,
        processes: [WorktreeProcess]? = nil, openFileHolders: Int? = nil, lastActivity: WorktreeActivity? = nil,
        containsOwnCWD: Bool = false, pathAllowed: Bool? = nil
    ) {
        self.worktree = worktree
        self.git = git
        self.gitError = gitError
        self.allocatedBytes = allocatedBytes
        self.cherryAllApplied = cherryAllApplied
        self.mergeTreeMatchesBase = mergeTreeMatchesBase
        self.commitsNotOnAnyRef = commitsNotOnAnyRef
        self.baseRef = baseRef
        self.pr = pr
        self.headCoveredByMergedPR = headCoveredByMergedPR
        self.processes = processes
        self.openFileHolders = openFileHolders
        self.lastActivity = lastActivity
        self.containsOwnCWD = containsOwnCWD
        self.pathAllowed = pathAllowed
    }
}
