import Foundation

public enum GitProbe: String, Sendable, Hashable, Codable {
    case discovery, status, stash, upstream, remotes, notOnRemote, defaultBranch, merged
    case lastCommit, worktreeList, shallow
}

public struct GitProbeFailure: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case timedOut, failed, outputTruncated }
    public var probe: GitProbe
    public var kind: Kind
    public var message: String

    public init(probe: GitProbe, kind: Kind, message: String) {
        self.probe = probe
        self.kind = kind
        self.message = message
    }
}

/// Fatal inspection errors. Partial probe failures are reported via `GitState.probeFailures` instead.
public enum GitInspectorError: Error, Sendable, Equatable {
    case gitUnavailable
    case gitTooOld(found: String)
    case pathNotFound(String)
    case notADirectory(String)
    case notARepository(String)
    case orphanedWorktree(gitdir: String)
    case unsafeRepository(String)
    case timedOut(GitProbe)
    case gitFailed(String)
}
