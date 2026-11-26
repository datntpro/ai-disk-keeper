import Foundation

/// Protected-path marking for the index (display only; cleanup keeps using the full guard).
///
/// Full `ProtectedPaths.evaluate` costs ~1 ms per path (Unicode folding of every component, ~90 globs over the
/// same home prefix). Every pattern has a finite length (a trailing `**` only means "and everything below"), so a
/// node is *settled* when (1) it lies deeper than every root and system-root key (root containment equals its
/// parent's) and (2) no anchored/exact-only pattern still matches its path prefix (tracked incrementally with a
/// cursor on both the lexical and the physical key). A settled node is protected exactly when it inherits that
/// from its parent or its own name matches a basename pattern. Everything else uses the full `evaluate`.
/// Not Sendable: confined to the walker thread.
final class IndexGuard {
    struct State {
        var protected = false     // protectedPath / protectedName: inherited by every descendant
        var system = false        // systemLocation: inherited
        var outside = false       // outsideAllowedRoots: inherited only below the root depth
        var lex: ProtectedPaths.AnchoredCursor?
        var phys: ProtectedPaths.AnchoredCursor?
    }

    private let pathGuard: ProtectedPaths
    private let rootPrefixLen: Int
    private let physicalBase: String
    /// Depth (in guard key components) of the root, or nil when the fast path is unsafe for this root.
    private let rootDepth: Int?
    private let maxRoot: Int
    private var nameCache: [String: Bool] = [:]

    init(pathGuard: ProtectedPaths, rootPath: String, physicalRoot: String) {
        self.pathGuard = pathGuard
        self.rootPrefixLen = rootPath == "/" ? 0 : rootPath.utf8.count
        self.physicalBase = physicalRoot == "/" ? "" : physicalRoot
        self.maxRoot = pathGuard.maxRootComponents
        let lex = PathCanonicalizer.key(rootPath).components
        let phys = PathCanonicalizer.key(physicalRoot).components
        // `/System/Volumes/Data` folding removes components from descendants' keys; do not count depth there.
        let fold = ["system", "volumes", "data"]
        func risky(_ c: [String]) -> Bool { c.count <= 3 && Array(fold.prefix(c.count)) == c }
        rootDepth = (risky(lex) || risky(phys)) ? nil : min(lex.count, phys.count)
    }

    /// Classify a node. `path` is the lexical fts path, `name` its last component, `level` the depth below the root.
    func classify(path: String, name: String, level: Int, parent: State?) -> (flags: NodeFlags, state: State) {
        guard let p = parent else { return full(path: path, lex: nil, phys: nil) }
        if p.protected { return ([.protected], p) }
        if p.system { return ([.outsideCleanableRoots], p) }
        guard let d = rootDepth, let pl = p.lex, let pp = p.phys else { return full(path: path, lex: nil, phys: nil) }
        let folded = PathCanonicalizer.fold(name)
        let lex = pathGuard.advance(pl, foldedComponent: folded)
        let phys = pathGuard.advance(pp, foldedComponent: folded)
        if d + level > maxRoot && lex.live.isEmpty && phys.live.isEmpty {
            var s = State(lex: lex, phys: phys)
            if p.outside { s.outside = true; return ([.outsideCleanableRoots], s) }
            let hit: Bool
            if let c = nameCache[name] { hit = c } else { hit = pathGuard.matchesBasename(name); nameCache[name] = hit }
            if hit { s.protected = true; return ([.protected], s) }
            return ([], s)
        }
        return full(path: path, lex: lex, phys: phys)
    }

    /// The reference implementation (also used by the differential tests). Cursors are carried into the state.
    func full(path: String, lex: ProtectedPaths.AnchoredCursor? = nil, phys: ProtectedPaths.AnchoredCursor? = nil)
        -> (flags: NodeFlags, state: State) {
        let suffix = String(path.utf8.dropFirst(rootPrefixLen)) ?? ""
        let physical = physicalBase + suffix
        var state = State()
        if rootDepth != nil {
            state.lex = lex ?? pathGuard.anchoredCursor(forKey: PathCanonicalizer.key(path).components)
            state.phys = phys ?? pathGuard.anchoredCursor(forKey: PathCanonicalizer.key(physical).components)
        }
        let verdict = pathGuard.evaluate(raw: path, resolution: .resolved(physical))
        guard case .denied(let d) = verdict else { return ([], state) }
        switch d.reason {
        case .protectedPath, .protectedName: state.protected = true; return ([.protected], state)
        case .systemLocation: state.system = true; return ([.outsideCleanableRoots], state)
        case .outsideAllowedRoots: state.outside = true; return ([.outsideCleanableRoots], state)
        default: return ([], state)
        }
    }
}
