import Foundation

/// The seven checks behind "Safe to clean". Order is display order.
public enum WorktreeCheckID: String, Sendable, Hashable, CaseIterable, Codable {
    case notMain, workDone, clean, noPreciousIgnored, commitsSafe, noProcess, idle
}

/// Fixed reasons a check could not be answered (localized by the UI).
public enum UnavailableReason: String, Sendable, Hashable {
    case noPathPolicy, notEnoughInfo, gitUnavailable, workingTreeNotInspected, topLevelDiffers
    case ignoredNotListed, ignoredTruncated, headUnknown, detachedNotChecked, processTableUnreadable
    case noActivityTime, remoteStateUnknown, noRemoteBase, gitFailed, probeFailed
}

/// Why a check passed or failed, in structured form so the UI can localize it. `description` is English (logs, H2).
public enum WorktreeEvidence: Sendable, Hashable {
    case allowed
    case isMain, isBare, isOrphan, isOwnCWD
    case protectedPath
    case mergedPR(number: Int)
    case closedPRAllPushed(number: Int)
    case ancestorOf(ref: String)
    case cherryApplied(ref: String)
    case mergeTreeEquals(ref: String)
    case workNotProven
    case clean
    case uncommitted(count: Int)
    case operationInProgress(String)
    case indexLock
    case locked
    case submodulesUnsafe
    case hiddenChanges
    case noPrecious
    case preciousIgnored(path: String)
    case branchKept(String)
    case detachedUnreachable(count: Int)
    case noProcesses
    case processesRunning(count: Int)
    case filesOpen(count: Int)
    case idle(since: Date)
    case recentActivity(at: Date)
    /// Content is in the default branch, but some commits exist on no remote.
    case unpushedCommits(count: Int)
    case unavailable(UnavailableReason)

    public var description: String {
        switch self {
        case .allowed: "Not a main checkout"
        case .isMain: "Main checkout"
        case .isBare: "Bare repository"
        case .isOrphan: "Git directory is missing"
        case .isOwnCWD: "This app is running here"
        case .protectedPath: "Protected path"
        case .mergedPR(let n): "Merged in PR #\(n)"
        case .closedPRAllPushed(let n): "PR #\(n) closed, all commits on a remote"
        case .ancestorOf(let r): "Already in \(r)"
        case .cherryApplied(let r): "Every commit has an equivalent in \(r)"
        case .mergeTreeEquals(let r): "Same content already in \(r)"
        case .workNotProven: "Not proven to be merged"
        case .clean: "Clean"
        case .uncommitted(let c): "\(c) uncommitted files"
        case .operationInProgress(let o): "\(o) in progress"
        case .indexLock: "Git index is locked"
        case .locked: "Worktree is locked"
        case .submodulesUnsafe: "A submodule has unpushed or uncommitted work"
        case .hiddenChanges: "Files hidden from git status"
        case .noPrecious: "No ignored secrets or data"
        case .preciousIgnored(let p): "Ignored secret file: \(p)"
        case .branchKept(let b): "Commits stay on branch \(b)"
        case .detachedUnreachable(let c): "\(c) commits only on this detached HEAD"
        case .noProcesses: "No process running here"
        case .processesRunning(let c): "\(c) processes running here"
        case .filesOpen(let c): "\(c) open files"
        case .idle: "Idle"
        case .recentActivity: "Recent activity"
        case .unpushedCommits(let c): "\(c) commits are on no remote"
        case .unavailable(let r): "Couldn't check: \(r.rawValue)"
        }
    }
}

public struct WorktreeCheck: Sendable, Hashable {
    public var id: WorktreeCheckID
    /// nil = unknown, which blocks cleaning (fail closed).
    public var passed: Bool?
    public var evidence: WorktreeEvidence
    public init(id: WorktreeCheckID, passed: Bool?, evidence: WorktreeEvidence) {
        self.id = id
        self.passed = passed
        self.evidence = evidence
    }
}

public enum WorktreeTier: String, Sendable, Hashable, Codable { case safe, review, keep }

public struct SafeCleanVerdict: Sendable, Hashable {
    public var checks: [WorktreeCheck]
    public var tier: WorktreeTier
    /// Eligible only if every check passed.
    public var eligible: Bool { checks.allSatisfy { $0.passed == true } }
    /// The first check that did not pass (failed or unknown): the chip shown in the list.
    public var firstBlocker: WorktreeCheck? { checks.first { $0.passed != true } }
    public func check(_ id: WorktreeCheckID) -> WorktreeCheck? { checks.first { $0.id == id } }
    public init(checks: [WorktreeCheck], tier: WorktreeTier) {
        self.checks = checks
        self.tier = tier
    }
}

/// Pure: decides whether a worktree is provably finished. Anything unknown is not eligible.
public enum WorktreeClassifier {
    public static func verdict(_ f: WorktreeFacts, now: Date, settings: AppSettings) -> SafeCleanVerdict {
        let checks = [
            notMain(f), workDone(f), clean(f), noPrecious(f), commitsSafe(f), noProcess(f), idle(f, now: now, hours: settings.worktreeIdleHours),
        ]
        return SafeCleanVerdict(checks: checks, tier: tier(f, checks))
    }

    static func tier(_ f: WorktreeFacts, _ checks: [WorktreeCheck]) -> WorktreeTier {
        if checks.allSatisfy({ $0.passed == true }) { return .safe }
        if f.worktree.isOrphan { return .review }
        let byID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })
        if byID[.notMain]?.passed == false { return .keep }
        // A known blocker keeps it; "clean, merely unproven" and unknowns are for the user to review.
        let blockers: [WorktreeCheckID] = [.clean, .noPreciousIgnored, .commitsSafe, .noProcess, .idle]
        if blockers.contains(where: { byID[$0]?.passed == false }) { return .keep }
        return .review
    }

    // MARK: checks

    /// Evidence when git facts are missing: an orphan says so, a git error is shown as is.
    static func gitGone(_ f: WorktreeFacts, _ fallback: UnavailableReason = .gitUnavailable) -> WorktreeEvidence {
        if f.worktree.isOrphan { return .isOrphan }
        if f.gitError != nil { return .unavailable(.gitFailed) }   // raw git text stays in facts.gitError, never shown
        return .unavailable(fallback)
    }

    static func notMain(_ f: WorktreeFacts) -> WorktreeCheck {
        func c(_ p: Bool?, _ e: WorktreeEvidence) -> WorktreeCheck { .init(id: .notMain, passed: p, evidence: e) }
        if f.worktree.isOrphan { return c(false, .isOrphan) }
        if f.worktree.isBare { return c(false, .isBare) }
        if f.worktree.isMain || f.git?.kind == .mainWorktree || f.git?.kind == .bare { return c(false, .isMain) }
        if f.containsOwnCWD { return c(false, .isOwnCWD) }
        switch f.pathAllowed {
        case false: return c(false, .protectedPath)
        case nil: return c(nil, .unavailable(.noPathPolicy))
        case true: return c(true, .allowed)
        }
    }

    static func workDone(_ f: WorktreeFacts) -> WorktreeCheck {
        func c(_ p: Bool?, _ e: WorktreeEvidence) -> WorktreeCheck { .init(id: .workDone, passed: p, evidence: e) }
        var undetermined = false
        var unpushed: Int?
        let base = f.baseRef.map(Self.shortRef) ?? "default branch"
        let remoteBase = f.baseRef?.hasPrefix("refs/remotes/") == true
        // Local proofs (ancestor / cherry / merge-tree) only count when they are against the remote-tracking
        // default branch AND every commit of this worktree is on a remote: a local `main` that has not been
        // pushed proves nothing about safety, and unpushed commits are never provably safe to forget.
        var pushedZero: Bool?
        if let count = f.git?.commitsNotOnAnyRemote {
            pushedZero = count.value == 0 && !count.isCapped
            if pushedZero == false { unpushed = count.value }
        }

        switch f.pr {
        case .merged(let n, _, _):
            if f.headCoveredByMergedPR == true { return c(true, .mergedPR(number: n)) }
            if f.headCoveredByMergedPR == nil { undetermined = true }
        case .closed(let n, _):
            if pushedZero == true { return c(true, .closedPRAllPushed(number: n)) }
            if pushedZero == nil { undetermined = true }
        case .unknown: undetermined = true
        case .open, .none, .disabled: break
        }
        if f.git == nil { return c(nil, gitGone(f)) }

        var contentProven = false
        if remoteBase {
            // An ancestor of origin/<default> is on a remote by definition.
            if f.git?.isMergedIntoDefault == true { return c(true, .ancestorOf(ref: base)) }
            if f.cherryAllApplied == true || f.mergeTreeMatchesBase == true {
                if pushedZero == true {
                    return c(true, f.cherryAllApplied == true ? .cherryApplied(ref: base) : .mergeTreeEquals(ref: base))
                }
                contentProven = true
            }
            if f.git?.isMergedIntoDefault == nil || f.cherryAllApplied == nil || f.mergeTreeMatchesBase == nil { undetermined = true }
        } else if f.baseRef == nil {
            undetermined = true
        } else {
            // Only a local branch to compare with: not a proof of anything on a remote.
            return c(false, .unavailable(.noRemoteBase))
        }
        if contentProven {
            if let u = unpushed { return c(false, .unpushedCommits(count: u)) }
            return c(nil, .unavailable(.remoteStateUnknown))
        }
        return c(undetermined ? nil : false, undetermined ? .unavailable(.notEnoughInfo) : .workNotProven)
    }

    static func clean(_ f: WorktreeFacts) -> WorktreeCheck {
        func c(_ p: Bool?, _ e: WorktreeEvidence) -> WorktreeCheck { .init(id: .clean, passed: p, evidence: e) }
        guard let g = f.git else { return c(nil, gitGone(f)) }
        if let wt = g.workingTree, !wt.isClean {
            return c(false, .uncommitted(count: wt.staged + wt.unstaged + wt.untracked + wt.conflicted + wt.submodulesDirty))
        }
        if let op = g.operationInProgress { return c(false, .operationInProgress(op.rawValue)) }
        if g.indexLockPresent { return c(false, .indexLock) }
        if g.worktreeLock != nil || f.worktree.gitEntry?.isLocked == true { return c(false, .locked) }
        if g.anySubmoduleUnpushedOrDirty { return c(false, .submodulesUnsafe) }
        if let h = g.hiddenFromStatus, h.total > 0 || h.modified > 0 || h.unverified > 0 { return c(false, .hiddenChanges) }
        let blind: Set<GitProbe> = [.status, .hiddenFiles, .submodules, .discovery]
        if g.probeFailures.contains(where: { blind.contains($0.probe) }) {
            return c(nil, .unavailable(.probeFailed))
        }
        if g.workingTree == nil || g.hiddenFromStatus == nil || g.submodules == nil && g.uninspectedSubmodules > 0 {
            return c(nil, .unavailable(.workingTreeNotInspected))
        }
        if g.topLevelMismatch { return c(nil, .unavailable(.topLevelDiffers)) }
        return c(true, .clean)
    }

    static func noPrecious(_ f: WorktreeFacts) -> WorktreeCheck {
        func c(_ p: Bool?, _ e: WorktreeEvidence) -> WorktreeCheck { .init(id: .noPreciousIgnored, passed: p, evidence: e) }
        guard let g = f.git else { return c(nil, gitGone(f)) }
        if let first = g.ignored?.preciousPaths.first { return c(false, .preciousIgnored(path: first)) }
        if g.probeFailures.contains(where: { $0.probe == .ignored }) { return c(nil, .unavailable(.ignoredNotListed)) }
        guard let ignored = g.ignored else { return c(nil, .unavailable(.ignoredNotListed)) }
        if ignored.isLowerBound { return c(nil, .unavailable(.ignoredTruncated)) }
        return c(true, .noPrecious)
    }

    static func commitsSafe(_ f: WorktreeFacts) -> WorktreeCheck {
        func c(_ p: Bool?, _ e: WorktreeEvidence) -> WorktreeCheck { .init(id: .commitsSafe, passed: p, evidence: e) }
        guard let head = f.git?.head else { return c(nil, gitGone(f, .headUnknown)) }
        switch head {
        case .branch(let name, _), .unborn(let name): return c(true, .branchKept(name))
        case .detached:
            guard let n = f.commitsNotOnAnyRef else { return c(nil, .unavailable(.detachedNotChecked)) }
            return n == 0 ? c(true, .branchKept("HEAD")) : c(false, .detachedUnreachable(count: n))
        }
    }

    static func noProcess(_ f: WorktreeFacts) -> WorktreeCheck {
        func c(_ p: Bool?, _ e: WorktreeEvidence) -> WorktreeCheck { .init(id: .noProcess, passed: p, evidence: e) }
        guard let procs = f.processes else { return c(nil, .unavailable(.processTableUnreadable)) }
        if !procs.isEmpty { return c(false, .processesRunning(count: procs.count)) }
        if let open = f.openFileHolders, open > 0 { return c(false, .filesOpen(count: open)) }
        return c(true, .noProcesses)
    }

    static func idle(_ f: WorktreeFacts, now: Date, hours: Int) -> WorktreeCheck {
        func c(_ p: Bool?, _ e: WorktreeEvidence) -> WorktreeCheck { .init(id: .idle, passed: p, evidence: e) }
        guard let last = f.lastActivity else { return c(nil, .unavailable(.noActivityTime)) }
        let limit = TimeInterval(AppSettings.clampWorktreeIdleHours(hours)) * 3600
        return now.timeIntervalSince(last.date) >= limit ? c(true, .idle(since: last.date)) : c(false, .recentActivity(at: last.date))
    }

    /// `refs/remotes/origin/main` → `origin/main`.
    static func shortRef(_ ref: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/"] where ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    }
}
