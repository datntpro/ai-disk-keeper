import Foundation

/// Facts about one git working tree. The inspector never classifies (Safe/Review/Keep is T14's job).
/// Contract: any `nil` field was not determined; treat unknown as NOT safe.
public struct GitState: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case mainWorktree, linkedWorktree, submodule, bare }
    public enum Head: Sendable, Hashable, Codable {
        case branch(name: String, oid: String)
        case detached(oid: String)
        case unborn(branch: String)
    }
    public enum Upstream: Sendable, Hashable, Codable {
        case none
        case tracking(ref: String, ahead: Int, behind: Int)
        case gone(ref: String)
    }
    public struct WorkingTree: Sendable, Hashable, Codable {
        public var staged: Int
        public var unstaged: Int
        public var untracked: Int
        public var conflicted: Int
        public var submodulesDirty: Int
        /// Output was truncated, so the counts are lower bounds.
        public var isLowerBound: Bool
        public var isClean: Bool { staged + unstaged + untracked + conflicted + submodulesDirty == 0 }
        public init(
            staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0,
            submodulesDirty: Int = 0, isLowerBound: Bool = false
        ) {
            self.staged = staged
            self.unstaged = unstaged
            self.untracked = untracked
            self.conflicted = conflicted
            self.submodulesDirty = submodulesDirty
            self.isLowerBound = isLowerBound
        }
    }
    /// "≥ value" when `isCapped`.
    public struct Count: Sendable, Hashable, Codable {
        public var value: Int
        public var isCapped: Bool
        public init(value: Int, isCapped: Bool) {
            self.value = value
            self.isCapped = isCapped
        }
    }
    /// `refs/stash` is repo-wide: shared by all worktrees of a repository.
    public struct Stash: Sendable, Hashable, Codable {
        public var total: Int
        /// Entries whose subject starts with `WIP on <branch>:` or `On <branch>:`.
        public var mentioningBranch: Int
        public var newestDate: Date?
        public init(total: Int, mentioningBranch: Int, newestDate: Date?) {
            self.total = total
            self.mentioningBranch = mentioningBranch
            self.newestDate = newestDate
        }
    }
    public struct DefaultBranch: Sendable, Hashable, Codable {
        public enum Source: String, Sendable, Hashable, Codable { case originHEAD, fallback }
        /// Full refname, e.g. `refs/remotes/origin/main`.
        public var ref: String
        public var source: Source
        public init(ref: String, source: Source) {
            self.ref = ref
            self.source = source
        }
    }
    public enum Operation: String, Sendable, Hashable, Codable { case merge, rebase, cherryPick, revert, bisect }
    public struct LastCommit: Sendable, Hashable, Codable {
        public var oid: String
        public var date: Date
        public var subject: String
        public init(oid: String, date: Date, subject: String) {
            self.oid = oid
            self.date = date
            self.subject = subject
        }
    }
    public struct WorktreeLock: Sendable, Hashable, Codable {
        public var reason: String?
        public init(reason: String?) { self.reason = reason }
    }

    /// Ignored (gitignored) content that `status` does not show. Ignored files are NOT regenerable
    /// by definition: `.env`, `*.pem`, local data. T14: any `preciousPaths` ⇒ at most Review;
    /// `unclassifiedPaths` non-empty ⇒ not Safe unless the user's rules say otherwise.
    public struct IgnoredSummary: Sendable, Hashable, Codable {
        public var count: Int
        public var isLowerBound: Bool
        /// Secret-like or data-like ignored paths (capped). Directories end with `/`.
        public var preciousPaths: [String]
        /// Ignored paths that are neither precious nor a known regenerable artifact (capped).
        public var unclassifiedPaths: [String]
        public init(count: Int, isLowerBound: Bool, preciousPaths: [String], unclassifiedPaths: [String]) {
            self.count = count
            self.isLowerBound = isLowerBound
            self.preciousPaths = preciousPaths
            self.unclassifiedPaths = unclassifiedPaths
        }
    }
    /// Index entries flagged assume-unchanged / skip-worktree: `status` never reports edits to them.
    /// T14: `total > 0` ⇒ not Safe (sparse checkouts set skip-worktree legitimately), `modified > 0` ⇒ dirty.
    public struct HiddenFromStatus: Sendable, Hashable, Codable {
        public var assumeUnchanged: Int
        public var skipWorktree: Int
        /// Hidden files present on disk whose content differs from the index (or are not regular files).
        public var modified: Int
        /// Hidden files whose content could not be compared (cap or hashing failure).
        public var unverified: Int
        public var total: Int { assumeUnchanged + skipWorktree }
        public init(assumeUnchanged: Int = 0, skipWorktree: Int = 0, modified: Int = 0, unverified: Int = 0) {
            self.assumeUnchanged = assumeUnchanged
            self.skipWorktree = skipWorktree
            self.modified = modified
            self.unverified = unverified
        }
    }

    /// As passed in (lexical, not resolved).
    public var path: String
    public var kind: Kind
    public var topLevel: String?
    public var gitDir: String
    public var commonDir: String
    public var head: Head?
    public var upstream: Upstream?
    public var hasRemotes: Bool?
    /// `rev-list --count --max-count=<cap> HEAD --not --remotes`.
    public var commitsNotOnAnyRemote: Count?
    public var workingTree: WorkingTree?
    public var stash: Stash?
    public var defaultBranch: DefaultBranch?
    /// `merge-base --is-ancestor`. Squash-merged branches read as false.
    public var isMergedIntoDefault: Bool?
    public var lastCommit: LastCommit?
    public var operationInProgress: Operation?
    public var indexLockPresent: Bool
    public var worktreeLock: WorktreeLock?
    public var isShallow: Bool?
    public var probeFailures: [GitProbeFailure]
    public var ignored: IgnoredSummary?
    public var hiddenFromStatus: HiddenFromStatus?
    /// Recursively inspected initialized submodules (their own unpushed commits / dirty state).
    /// T14: any submodule with unpushed commits or a dirty tree ⇒ not Safe. nil = not probed.
    public var submodules: [GitState]?
    /// `topLevel` is not the inspected path (core.worktree redirect or not a root): status describes elsewhere.
    public var topLevelMismatch: Bool

    public init(
        path: String, kind: Kind, topLevel: String? = nil, gitDir: String, commonDir: String,
        head: Head? = nil, upstream: Upstream? = nil, hasRemotes: Bool? = nil,
        commitsNotOnAnyRemote: Count? = nil, workingTree: WorkingTree? = nil, stash: Stash? = nil,
        defaultBranch: DefaultBranch? = nil, isMergedIntoDefault: Bool? = nil,
        lastCommit: LastCommit? = nil, operationInProgress: Operation? = nil,
        indexLockPresent: Bool = false, worktreeLock: WorktreeLock? = nil, isShallow: Bool? = nil,
        probeFailures: [GitProbeFailure] = [], ignored: IgnoredSummary? = nil,
        hiddenFromStatus: HiddenFromStatus? = nil, submodules: [GitState]? = nil,
        topLevelMismatch: Bool = false
    ) {
        self.ignored = ignored
        self.hiddenFromStatus = hiddenFromStatus
        self.submodules = submodules
        self.topLevelMismatch = topLevelMismatch
        self.path = path
        self.kind = kind
        self.topLevel = topLevel
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.head = head
        self.upstream = upstream
        self.hasRemotes = hasRemotes
        self.commitsNotOnAnyRemote = commitsNotOnAnyRemote
        self.workingTree = workingTree
        self.stash = stash
        self.defaultBranch = defaultBranch
        self.isMergedIntoDefault = isMergedIntoDefault
        self.lastCommit = lastCommit
        self.operationInProgress = operationInProgress
        self.indexLockPresent = indexLockPresent
        self.worktreeLock = worktreeLock
        self.isShallow = isShallow
        self.probeFailures = probeFailures
    }
}

public struct GitWorktreeEntry: Sendable, Hashable, Codable {
    public var path: String
    public var head: String?
    /// e.g. `refs/heads/x`
    public var branch: String?
    public var isDetached: Bool
    public var isBare: Bool
    public var lockReason: String?
    public var isLocked: Bool
    public var prunableReason: String?
    public var isPrunable: Bool
    /// First entry of the list.
    public var isMain: Bool

    public init(
        path: String, head: String? = nil, branch: String? = nil, isDetached: Bool = false,
        isBare: Bool = false, lockReason: String? = nil, isLocked: Bool = false,
        prunableReason: String? = nil, isPrunable: Bool = false, isMain: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.lockReason = lockReason
        self.isLocked = isLocked
        self.prunableReason = prunableReason
        self.isPrunable = isPrunable
        self.isMain = isMain
    }
}

/// Contents of a `.git` *file* ("gitdir: <path>") in a linked worktree or submodule.
public struct GitFileInfo: Sendable, Hashable, Codable {
    /// Absolute; resolved against the directory when the file holds a relative path.
    public var gitdir: String
    public var gitdirExists: Bool
    /// From `<gitdir>/commondir` if readable.
    public var commonDir: String?

    public init(gitdir: String, gitdirExists: Bool, commonDir: String?) {
        self.gitdir = gitdir
        self.gitdirExists = gitdirExists
        self.commonDir = commonDir
    }
}
