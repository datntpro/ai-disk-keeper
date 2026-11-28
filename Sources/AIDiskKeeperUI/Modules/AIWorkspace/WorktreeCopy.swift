import DiskKeeperCore
import Foundation

/// Every user-visible string of the Worktrees inventory. Keys use the `wt.` prefix.
enum WorktreeCopy {
    static var tabInventory: String { loc("wt.tab.inventory", "Inventory") }
    static var tabArtifacts: String { loc("wt.tab.artifacts", "Build artifacts") }
    static var colName: String { loc("wt.col.name", "Worktree") }
    static var colRepo: String { loc("wt.col.repo", "Repository") }
    static var colBranch: String { loc("wt.col.branch", "Branch") }
    static var colSize: String { loc("wt.col.size", "Size") }
    static var colPR: String { loc("wt.col.pr", "Pull request") }
    static var colChanges: String { loc("wt.col.changes", "Changes") }
    static var colProcesses: String { loc("wt.col.processes", "Processes") }
    static var colActivity: String { loc("wt.col.activity", "Last activity") }
    static var colVerdict: String { loc("wt.col.verdict", "Status") }
    static var filterAll: String { loc("wt.filter.all", "All") }
    static var filterSafe: String { loc("wt.filter.safe", "Safe to clean") }
    static var filterInUse: String { loc("wt.filter.inUse", "In use") }
    static var filterChanges: String { loc("wt.filter.changes", "Has changes") }
    static var refresh: String { loc("wt.refresh", "Refresh") }
    static var selectSafe: String { loc("wt.selectSafe", "Select safe") }
    static var selectSafeHelp: String { loc("wt.selectSafe.help", "Cleaning worktrees isn't available yet. This list is read-only.") }
    static var safe: String { loc("wt.verdict.safe", "Safe to clean") }
    static var review: String { loc("wt.verdict.review", "Review") }
    static var keep: String { loc("wt.verdict.keep", "Keep") }
    static var prNone: String { loc("wt.pr.none", "No PR") }
    static var prUnknown: String { loc("wt.pr.unknown", "Unknown") }
    static var prOff: String { loc("wt.pr.off", "gh off") }
    static func prMerged(_ n: Int) -> String { loc("wt.pr.merged", "#\(n) Merged") }
    static func prClosed(_ n: Int) -> String { loc("wt.pr.closed", "#\(n) Closed") }
    static func prOpen(_ n: Int) -> String { loc("wt.pr.open", "#\(n) Open") }
    static func orcaPR(_ n: Int) -> String { loc("wt.pr.orcaHint", "Orca links PR #\(n) (not verified)") }
    static var changesClean: String { loc("wt.changes.clean", "Clean") }
    static func changesFiles(_ n: Int) -> String { loc("wt.changes.files", "\(n) files") }
    static var dash: String { "–" }
    static var emptyTitle: String { loc("wt.empty.title", "No worktrees found") }
    static var emptyMessage: String { loc("wt.empty.message", "Linked git worktrees in your project folders and Orca appear here.") }
    static var filteredEmptyTitle: String { loc("wt.filteredEmpty.title", "Nothing matches this filter") }
    static var loading: String { loc("wt.loading", "Looking at your worktrees…") }
    static var selectOne: String { loc("wt.selectOne", "Select a worktree to see why it is, or isn't, safe to clean.") }
    static var inspectorChecks: String { loc("wt.inspector.checks", "Checks") }
    static var inspectorProcesses: String { loc("wt.inspector.processes", "Running here") }
    static var inspectorPath: String { loc("wt.inspector.path", "Location") }
    static var inspectorHint: String { loc("wt.inspector.hint", "Cleaning keeps the branch. Nothing here is changed by looking.") }
    static func inspectorActivity(_ source: String) -> String { loc("wt.inspector.activity", "Last activity (\(source))") }
    static var passed: String { loc("wt.check.passed", "Passed") }
    static var failed: String { loc("wt.check.failed", "Not passed") }
    static var unknownCheck: String { loc("wt.check.unknown", "Couldn't check") }

    static func checkName(_ id: WorktreeCheckID) -> String {
        switch id {
        case .notMain: loc("wt.check.notMain", "Not a main checkout")
        case .workDone: loc("wt.check.workDone", "Work is finished")
        case .clean: loc("wt.check.clean", "No uncommitted changes")
        case .noPreciousIgnored: loc("wt.check.noPrecious", "No ignored secrets or data")
        case .commitsSafe: loc("wt.check.commitsSafe", "Commits are kept")
        case .noProcess: loc("wt.check.noProcess", "Nothing running here")
        case .idle: loc("wt.check.idle", "Idle long enough")
        }
    }

    static func source(_ s: ActivitySource) -> String {
        switch s {
        case .orca: loc("wt.activity.orca", "Orca")
        case .index: loc("wt.activity.index", "git index")
        case .headLog: loc("wt.activity.headLog", "git log")
        case .head: loc("wt.activity.head", "git HEAD")
        case .files: loc("wt.activity.files", "files")
        }
    }

    static func evidence(_ e: WorktreeEvidence, now: Date = Date()) -> String {
        switch e {
        case .allowed: loc("wt.ev.allowed", "A linked worktree")
        case .isMain: loc("wt.ev.isMain", "This is the main checkout")
        case .isBare: loc("wt.ev.isBare", "This is a bare repository")
        case .isOrphan: loc("wt.ev.isOrphan", "Its git directory is missing")
        case .isOwnCWD: loc("wt.ev.isOwnCWD", "AI Disk Keeper is running here")
        case .protectedPath: loc("wt.ev.protected", "This folder is protected")
        case .mergedPR(let n): loc("wt.ev.mergedPR", "Merged in PR #\(n)")
        case .closedPRAllPushed(let n): loc("wt.ev.closedPR", "PR #\(n) closed, all commits on origin")
        case .ancestorOf(let r): loc("wt.ev.ancestor", "Already in \(r)")
        case .cherryApplied(let r): loc("wt.ev.cherry", "Every commit has an equivalent in \(r)")
        case .mergeTreeEquals(let r): loc("wt.ev.mergeTree", "Same content already in \(r)")
        case .workNotProven: loc("wt.ev.notProven", "Not proven to be merged")
        case .clean: loc("wt.ev.clean", "No changes")
        case .uncommitted(let n): loc("wt.ev.uncommitted", "\(n) uncommitted files")
        case .operationInProgress(let o): loc("wt.ev.operation", "A \(o) is in progress")
        case .indexLock: loc("wt.ev.indexLock", "Git is working here (index locked)")
        case .locked: loc("wt.ev.locked", "The worktree is locked")
        case .submodulesUnsafe: loc("wt.ev.submodules", "A submodule has unpushed or uncommitted work")
        case .hiddenChanges: loc("wt.ev.hidden", "Files are hidden from git status")
        case .noPrecious: loc("wt.ev.noPrecious", "No ignored secret or data files")
        case .preciousIgnored(let p): loc("wt.ev.precious", "Ignored secret file: \(p)")
        case .branchKept(let b): loc("wt.ev.branchKept", "Commits stay on \(b)")
        case .detachedUnreachable(let n): loc("wt.ev.detached", "\(n) commits exist only here")
        case .noProcesses: loc("wt.ev.noProcesses", "No process is running here")
        case .processesRunning(let n): loc("wt.ev.processes", "\(n) processes running here")
        case .filesOpen(let n): loc("wt.ev.filesOpen", "\(n) files are open")
        case .idle(let d): loc("wt.ev.idle", "Last activity \(Formatting.relative(d, now: now)) ago")
        case .recentActivity(let d): loc("wt.ev.recent", "Last activity \(Formatting.relative(d, now: now)) ago")
        case .unpushedCommits(let n): loc("wt.ev.unpushed", "\(n) commits are on no remote, so they are not safe to forget")
        case .unavailable(let r): unavailable(r)
        }
    }

    static func unavailable(_ r: UnavailableReason) -> String {
        switch r {
        case .noPathPolicy: loc("wt.ev.un.noPathPolicy", "Couldn't check: no path protection policy")
        case .notEnoughInfo: loc("wt.ev.un.notEnoughInfo", "Couldn't check: not enough information")
        case .gitUnavailable: loc("wt.ev.un.git", "Couldn't check: git state unavailable")
        case .workingTreeNotInspected: loc("wt.ev.un.workingTree", "Couldn't check: working tree not inspected")
        case .topLevelDiffers: loc("wt.ev.un.topLevel", "Couldn't check: git top level differs")
        case .ignoredNotListed: loc("wt.ev.un.ignored", "Couldn't check: ignored files not listed")
        case .ignoredTruncated: loc("wt.ev.un.ignoredTruncated", "Couldn't check: ignored files list truncated")
        case .headUnknown: loc("wt.ev.un.head", "Couldn't check: HEAD unknown")
        case .detachedNotChecked: loc("wt.ev.un.detached", "Couldn't check: detached HEAD not examined")
        case .processTableUnreadable: loc("wt.ev.un.processes", "Couldn't check: running processes unreadable")
        case .noActivityTime: loc("wt.ev.un.activity", "Couldn't check: no activity time")
        case .remoteStateUnknown: loc("wt.ev.un.remote", "Couldn't check: which commits are on a remote")
        case .gitFailed: loc("wt.ev.un.gitFailed", "Couldn't check: git couldn't read this worktree")
        case .probeFailed: loc("wt.ev.un.probeFailed", "Couldn't check: a git command failed or timed out")
        case .noRemoteBase: loc("wt.ev.un.noRemoteBase", "No remote default branch to compare with")
        }
    }

    static func warning(_ w: InventoryWarning) -> String {
        switch w {
        case .orcaUnavailable(let why): loc("wt.warn.orca", "Orca's list isn't available (\(why)); using git only.")
        case .repositoryFailed(let path, _): loc("wt.warn.repo", "Couldn't list worktrees of \((path as NSString).lastPathComponent).")
        case .prLookupFailed(let repo, let why): loc("wt.warn.pr", "Couldn't check pull requests for \((repo as NSString).lastPathComponent): \(why)")
        case .processTableUnreadable: loc("wt.warn.processes", "Couldn't read running processes, so nothing is marked safe.")
        }
    }

    // GitHub opt-in
    static var ghToggle: String { loc("wt.gh.toggle", "Check PR status with GitHub CLI") }
    static var ghToggleHelp: String { loc("wt.gh.help", "Off by default. Without it, “merged” is proven from your local git history only.") }
    static var ghConsentTitle: String { loc("wt.gh.consent.title", "Check pull requests with GitHub?") }
    static var ghConsentMessage: String {
        loc("wt.gh.consent.message", "This runs `gh pr list`, which contacts GitHub with your gh login. Nothing else leaves the Mac.")
    }
    static var ghConsentAllow: String { loc("wt.gh.consent.allow", "Turn on") }
    static var ghConsentCancel: String { loc("wt.gh.consent.cancel", "Cancel") }

    // Settings
    static var settingsTitle: String { loc("wt.settings.title", "Worktrees") }
    static var settingsIdle: String { loc("wt.settings.idle", "Idle time before a worktree can be cleaned") }
    static func hours(_ n: Int) -> String { loc("wt.settings.hours", "\(n) h") }
    static var settingsIdleHelp: String { loc("wt.settings.idle.help", "A worktree with activity more recent than this is always kept.") }
}
