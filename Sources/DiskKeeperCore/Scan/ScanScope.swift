import Foundation

/// User-chosen limits on what a scan reports. `.unrestricted` is the engine's original behaviour.
public struct ScanScope: Sendable, Hashable {
    /// Absolute, lexically normalized.
    public var excludedPaths: [String]
    public var disabledTools: Set<ToolID>
    /// Absolute. Carried for the worktree / build-artifact scanners; `RuleScanner` ignores it.
    public var projectRoots: [String]

    public static let unrestricted = ScanScope(excludedPaths: [], disabledTools: [], projectRoots: [])

    public init(excludedPaths: [String] = [], disabledTools: Set<ToolID> = [], projectRoots: [String] = []) {
        self.excludedPaths = excludedPaths
        self.disabledTools = disabledTools
        self.projectRoots = projectRoots
    }

    /// False when the item's tool is disabled, or its path equals, lies inside, or contains an excluded path
    /// (the "contains" case: cleaning a parent would trash the excluded folder). Compared with the same alias
    /// and case folding as `PathClaimSet`.
    public func allows(_ item: ScanItem) -> Bool {
        if disabledTools.contains(item.tool) { return false }
        guard !excludedPaths.isEmpty else { return true }
        let key = PathCanonicalizer.key(item.path).components
        for excluded in excludedPaths {
            let ex = PathCanonicalizer.key(excluded).components
            let n = min(key.count, ex.count)
            if key.prefix(n) == ex.prefix(n) { return false }
        }
        return true
    }
}
