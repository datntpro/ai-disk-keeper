import Foundation

/// User-chosen limits on what a scan reports. `.unrestricted` is the engine's original behaviour.
public struct ScanScope: Sendable, Hashable {
    /// Absolute, lexically normalized.
    public let excludedPaths: [String]
    public let disabledTools: Set<ToolID>
    /// Absolute. Carried for the worktree / build-artifact scanners; `RuleScanner` ignores it.
    public let projectRoots: [String]
    /// Lexical and symlink-resolved component keys of every excluded path, computed once.
    private let excludedKeys: [[String]]

    public static let unrestricted = ScanScope(excludedPaths: [], disabledTools: [], projectRoots: [])

    public init(excludedPaths: [String] = [], disabledTools: Set<ToolID> = [], projectRoots: [String] = []) {
        self.excludedPaths = excludedPaths
        self.disabledTools = disabledTools
        self.projectRoots = projectRoots
        let resolver = SystemPathResolver()
        self.excludedKeys = excludedPaths.flatMap { Self.keys(for: $0, resolver: resolver) }
    }

    /// False when the item's tool is disabled, or its path equals, lies inside, or contains an excluded path
    /// (the "contains" case: cleaning a parent would trash the excluded folder). Compared with the same alias
    /// and case folding as `PathClaimSet`.
    public func allows(_ item: ScanItem) -> Bool {
        if disabledTools.contains(item.tool) { return false }
        guard !excludedPaths.isEmpty else { return true }
        for key in Self.keys(for: item.path, resolver: SystemPathResolver()) {
            for ex in excludedKeys {
                let n = min(key.count, ex.count)
                if key.prefix(n) == ex.prefix(n) { return false }
            }
        }
        return true
    }

    /// The lexical key plus, when the path resolves, the physical key (symlinks followed; the deepest existing
    /// prefix is resolved for paths that don't exist). Matching either form is fail-safe: it can only exclude more.
    private static func keys(for path: String, resolver: any PathResolving) -> [[String]] {
        var out = [PathCanonicalizer.key(path).components]
        if case .resolved(let real) = resolver.resolve(path) {
            let k = PathCanonicalizer.key(real).components
            if k != out[0] { out.append(k) }
        }
        return out
    }
}
