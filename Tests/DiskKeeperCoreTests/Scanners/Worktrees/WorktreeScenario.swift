import XCTest

@testable import DiskKeeperCore

/// A bare origin, a main repo and one linked worktree per case, built with real git in a temp dir.
final class WorktreeScenario {
    let fx: GitFixture
    let repo: URL
    let origin: URL
    let wtRoot: URL

    init() throws {
        fx = try GitFixture()
        let r = try fx.makeRepoWithOrigin("proj")
        repo = r.repo
        origin = r.origin
        wtRoot = try fx.tmp.dir("home/work")
        try fx.write(repo, ".gitignore", ".env\n")
        try fx.git(["add", ".gitignore"], in: repo)
        try fx.git(["commit", "-q", "-m", "ignore"], in: repo)
        try fx.push(repo, "main")
    }

    func wt(_ name: String, branch: String? = nil, commit: Bool = false) throws -> URL {
        let url = wtRoot.appendingPathComponent(name)
        try fx.addWorktree(repo, url, branch: branch ?? name)
        if commit { try fx.commit(url, file: "\(name).txt", msg: "work \(name)") }
        return url
    }

    func advanceOrigin() throws { try fx.push(repo, "main") }

    func ffMerged() throws -> URL {
        let w = try wt("ff", commit: true)
        try fx.git(["merge", "--ff-only", "-q", "ff"], in: repo)
        try advanceOrigin()
        return w
    }

    func squashMerged(name: String = "sq", pushBranch: Bool = false) throws -> URL {
        let w = try wt(name, commit: true)
        if pushBranch { try fx.git(["push", "-q", "origin", name], in: w) }
        try fx.git(["merge", "--squash", name], in: repo)
        try fx.git(["commit", "-q", "-m", "squash \(name)"], in: repo)
        try advanceOrigin()
        return w
    }

    func cherryPicked(name: String = "cp", pushBranch: Bool = false) throws -> URL {
        let w = try wt(name, commit: true)
        if pushBranch { try fx.git(["push", "-q", "origin", name], in: w) }
        let sha = try fx.git(["rev-parse", name], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try fx.git(["cherry-pick", sha], in: repo)
        try advanceOrigin()
        return w
    }

    func unmerged() throws -> URL { try wt("um", commit: true) }

    func detachedWithUnreachableCommit() throws -> URL {
        let url = wtRoot.appendingPathComponent("det")
        try fx.addDetachedWorktree(repo, url)
        try fx.commit(url, file: "det.txt", msg: "only here")
        return url
    }

    func orphan() throws -> URL {
        let w = try wt("orph", commit: true)
        let name = try fx.git(["rev-parse", "--git-dir"], in: w).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(atPath: name)
        return w
    }

    func rebaseInProgress() throws -> URL {
        let w = try wt("reb")
        try fx.commit(w, file: "README.md", msg: "branch edit", content: "branch\n")
        try fx.commit(repo, file: "README.md", msg: "main edit", content: "main\n")
        try fx.git(["rebase", "main"], in: w, allowFail: true)
        return w
    }

    func inspector() -> GitInspector { fx.inspector() }

    func protectedPaths() throws -> ProtectedPaths {
        try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tmp.path("scratch"))
    }

    func inventory(processes: any ProcessTableReading = FakeProcessTable([]), orca: OrcaListResult = OrcaListResult(),
                   pr: any PRStatusSource = DisabledPRStatusSource(), now: Date = Date().addingTimeInterval(86400 * 30),
                   ownCWDs: [String] = ["/"]) throws -> WorktreeInventory {
        WorktreeInventory(dependencies: .init(
            git: inspector(), orca: StaticOrcaWorktrees(orca), prSource: pr, processes: processes, protectedPaths: try protectedPaths(),
            home: fx.home, projectRoots: [fx.home, fx.root.path], ownCWDs: ownCWDs,
            workspaceParents: [], inRepoFolders: []), now: { now })
    }
}

struct FakeProcessTable: ProcessTableReading {
    var records: [ProcessRecord]?
    init(_ records: [ProcessRecord]?) { self.records = records }
    func snapshot() -> ProcessTableSnapshot? {
        records.map { ProcessTableSnapshot(at: .now, wall: Date(), records: $0) }
    }
}

struct FakePRSource: PRStatusSource {
    var lookupResult: PRLookup
    func lookup(repository: String, remoteURL: String?) async -> PRLookup { lookupResult }
}

/// Every path under `root` with size and mtime, for byte-level "nothing was written" checks.
func treeSnapshot(_ root: String) -> [String: String] {
    var out: [String: String] = [:]
    guard let e = FileManager.default.enumerator(atPath: root) else { return out }
    for case let rel as String in e {
        let attrs = try? FileManager.default.attributesOfItem(atPath: root + "/" + rel)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let m = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        out[rel] = "\(size)@\(m)"
    }
    return out
}
