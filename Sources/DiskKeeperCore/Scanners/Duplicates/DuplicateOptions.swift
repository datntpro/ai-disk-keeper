import Foundation

/// How the "keep" copy of a group is chosen. All rules end with the same tie-breaks:
/// oldest creation time, then shortest path, then the canonical path key.
public enum KeeperRule: String, Sendable, Codable, CaseIterable {
    case oldest, insideGitRepo, shortestPath
}

/// Options and scope filter for the duplicate finder. Defaults are PLAN D7: files of at least 1 MB in Home,
/// excluding `~/Library` and the media libraries (already protected), keeping the oldest copy.
public struct DuplicateOptions: Sendable, Hashable {
    /// D7 "≥ 1 MB" (decimal, matches the UI copy).
    public var minimumLogicalBytes: Int64 = 1_000_000
    public var scopeRoot: String
    public var excludedRoots: [String]
    /// Skip any path component (below `scopeRoot`) that starts with "." (.git, .venv, .Trash, .ollama, .npm, .cache…).
    public var skipHiddenComponents = true
    public var skipComponentNames: Set<String> = ["node_modules", "Pods", "DerivedData", "site-packages"]
    /// Blocking reads in flight.
    public var maxConcurrentHashes = 4
    public var keeperRule: KeeperRule = .oldest
    /// TEST-ONLY.
    var _cloneProbe: (@Sendable (String) -> CloneInfo)?
    /// TEST-ONLY: pretend a path is dataless.
    var _datalessOverride: (@Sendable (String) -> Bool)?

    public init(scopeRoot: String, excludedRoots: [String]) {
        self.scopeRoot = scopeRoot
        self.excludedRoots = excludedRoots
    }

    /// D7 defaults for an environment: scope = Home, excluded = `~/Library`.
    public init(environment: PathEnvironment) {
        self.init(scopeRoot: environment.home, excludedRoots: [environment.home + "/Library"])
    }

    public static func == (l: DuplicateOptions, r: DuplicateOptions) -> Bool {
        l.minimumLogicalBytes == r.minimumLogicalBytes && l.scopeRoot == r.scopeRoot
            && l.excludedRoots == r.excludedRoots && l.skipHiddenComponents == r.skipHiddenComponents
            && l.skipComponentNames == r.skipComponentNames
            && l.maxConcurrentHashes == r.maxConcurrentHashes && l.keeperRule == r.keeperRule
    }

    public func hash(into h: inout Hasher) {
        h.combine(minimumLogicalBytes); h.combine(scopeRoot); h.combine(excludedRoots)
        h.combine(skipHiddenComponents); h.combine(skipComponentNames);
        h.combine(maxConcurrentHashes); h.combine(keeperRule)
    }
}
