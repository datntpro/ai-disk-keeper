import Foundation

/// Scope and floor for the large-file report. The UI filters up from the floor (default 500 MB).
public struct LargeFileOptions: Sendable, Hashable {
    /// Collect floor (decimal MB, matches the UI copy). The UI picks 100 MB … 5 GB on top of it.
    public var minimumBytes: Int64 = 100_000_000
    public var scopeRoot: String
    public var excludedRoots: [String]
    /// Skip any component below `scopeRoot` that starts with "." (`.ollama`, `.docker`…: other modules own those).
    public var skipHiddenComponents = true

    public init(scopeRoot: String, excludedRoots: [String]) {
        self.scopeRoot = scopeRoot
        self.excludedRoots = excludedRoots
    }

    /// Scope = Home, excluded = `~/Library` (AI Workspace and System Junk handle that with tool-aware rules).
    public init(environment: PathEnvironment) {
        self.init(scopeRoot: environment.home, excludedRoots: [environment.home + "/Library"])
    }
}
