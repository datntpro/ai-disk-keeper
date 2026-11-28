import Foundation

public struct OrcaListResult: Sendable, Hashable {
    public var rows: [OrcaWorktreeRow]
    /// Why the source was skipped (not installed, failed, bad output); nil when the list was read.
    public var warning: String?
    public init(rows: [OrcaWorktreeRow] = [], warning: String? = nil) {
        self.rows = rows
        self.warning = warning
    }
}

public protocol OrcaWorktreeListing: Sendable {
    func list() async -> OrcaListResult
}

/// Reads `orca worktree list --json` from the installed Orca app. The binary comes from absolute candidate paths
/// only (never `PATH`); the call is local, with a minimal environment and no remote/pairing flags.
public struct OrcaWorktreeSource: OrcaWorktreeListing {
    public let candidates: [String]
    public let home: String
    private let runner: ProcessRunner
    private let timeout: Duration

    public static func defaultCandidates(home: String) -> [String] {
        ["/Applications/Orca.app/Contents/Resources/bin/orca", home + "/Applications/Orca.app/Contents/Resources/bin/orca"]
    }

    public init(home: String, candidates: [String]? = nil, runner: ProcessRunner = ProcessRunner(), timeout: Duration = .seconds(10)) {
        self.home = home
        self.candidates = candidates ?? Self.defaultCandidates(home: home)
        self.runner = runner
        self.timeout = timeout
    }

    public func list() async -> OrcaListResult {
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return OrcaListResult(warning: "Orca is not installed")
        }
        do {
            let r = try await runner.run(
                executable: URL(fileURLWithPath: binary), arguments: ["worktree", "list", "--json"],
                environment: ["HOME": home, "PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
            guard r.exitStatus == 0 else { return OrcaListResult(warning: "orca exited with status \(r.exitStatus)") }
            guard !r.stdoutTruncated else { return OrcaListResult(warning: "orca output too large") }
            return Self.parse(r.stdout)
        } catch is CancellationError {
            return OrcaListResult(warning: "cancelled")
        } catch {
            return OrcaListResult(warning: "orca could not run: \(error)")
        }
    }

    /// Accepts the `{ok, result: {worktrees: [...]}}` envelope (or a bare `{worktrees}` / array). Unknown keys are ignored.
    public static func parse(_ data: Data) -> OrcaListResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return OrcaListResult(warning: "orca output is not JSON") }
        var rows: [Any]?
        if let obj = json as? [String: Any] {
            if let ok = obj["ok"] as? Bool, !ok { return OrcaListResult(warning: "orca reported an error") }
            if let result = obj["result"] as? [String: Any] { rows = result["worktrees"] as? [Any] }
            if rows == nil { rows = obj["worktrees"] as? [Any] }
        } else if let arr = json as? [Any] {
            rows = arr
        }
        guard let rows else { return OrcaListResult(warning: "orca output has no worktrees") }
        return OrcaListResult(rows: rows.compactMap { ($0 as? [String: Any]).flatMap(row(from:)) })
    }

    private static func row(from o: [String: Any]) -> OrcaWorktreeRow? {
        guard let path = o["path"] as? String, path.hasPrefix("/") else { return nil }
        func str(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var branch = str("branch")
        if let b = branch, b.hasPrefix("refs/heads/") { branch = String(b.dropFirst("refs/heads/".count)) }
        var date: Date?
        if let ms = (o["lastActivityAt"] as? NSNumber)?.doubleValue, ms > 0 { date = Date(timeIntervalSince1970: ms / 1000) }
        var pr: Int?
        if let n = o["linkedPR"] as? Int { pr = n } else if let d = o["linkedPR"] as? [String: Any] { pr = d["number"] as? Int }
        return OrcaWorktreeRow(
            instanceID: str("instanceId"), path: path, repoID: str("repoId"), branch: branch, head: str("head"),
            isMain: (o["isMainWorktree"] as? Bool) ?? false, isBare: (o["isBare"] as? Bool) ?? false,
            displayName: str("displayName"), lastActivityAt: date, linkedPR: pr, workspaceStatus: str("workspaceStatus"))
    }
}

/// Test double and "Orca not used" implementation.
public struct StaticOrcaWorktrees: OrcaWorktreeListing {
    public var result: OrcaListResult
    public init(_ result: OrcaListResult = OrcaListResult()) { self.result = result }
    public func list() async -> OrcaListResult { result }
}
