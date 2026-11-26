import Foundation

/// Protected-path marking for the index (display only; cleanup keeps using the full guard).
///
/// Full `ProtectedPaths.evaluate` costs ~1 ms per path. The verdict is a function of the lexical key and the
/// physical key (lexical first), so this tracks one verdict class per key. A node is *settled* when, for both keys,
/// it is deeper than every root/system-root key (so root containment equals its parent's) and no anchored/exact-only
/// pattern can still apply (cursor empty; a fully matched anchored pattern stays in the cursor, which covers
/// patterns at or above a root, whose node evaluates as a container). A settled key inherits `protected`, `system`
/// or `outside` from its parent; otherwise it becomes `protected` only through a basename pattern on its own name.
/// Everything else is computed from the key by the guard itself. Not Sendable: confined to the walker thread.
final class IndexGuard {
    typealias Kind = ProtectedPaths.IndexKind
    typealias Cursor = ProtectedPaths.AnchoredCursor

    struct State {
        var lex: Kind = .none
        var phys: Kind = .none
        var lexCursor: Cursor?
        var physCursor: Cursor?

        /// Same precedence as `evaluate`: the lexical verdict wins, then the physical one.
        var flags: NodeFlags {
            switch lex != .none ? lex : phys {
            case .protected: return [.protected]
            case .system, .outside: return [.outsideCleanableRoots]
            case .none: return []
            }
        }
        var isProtected: Bool { (lex != .none ? lex : phys) == .protected }
    }

    private let pathGuard: ProtectedPaths
    private let rootPrefixLen: Int
    private let physicalBase: String
    private let enabled: Bool
    private let maxRoot: Int
    private var nameCache: [String: Bool] = [:]

    init(pathGuard: ProtectedPaths, rootPath: String, physicalRoot: String) {
        self.pathGuard = pathGuard
        self.rootPrefixLen = rootPath == "/" ? 0 : rootPath.utf8.count
        self.physicalBase = physicalRoot == "/" ? "" : physicalRoot
        self.maxRoot = pathGuard.maxRootComponents
        // Keys of descendants of "/" or "/System[/Volumes]" lose their `/System/Volumes/Data` prefix, so their
        // key depth is not monotonic. Use the full computation everywhere for such roots.
        let fold = ["system", "volumes", "data"]
        func risky(_ p: String) -> Bool {
            let c = PathNormalization.components(p).map { PathCanonicalizer.fold(String($0)) }
            return c.count < 3 && Array(fold.prefix(c.count)) == c
        }
        enabled = !(risky(rootPath) || risky(physicalRoot))
    }

    /// Classify a node. `path` is the lexical fts path, `name` its last component, `level` the depth below the root.
    func classify(path: String, name: String, level: Int, parent: State?) -> (flags: NodeFlags, state: State) {
        guard enabled, let p = parent, let pl = p.lexCursor, let pp = p.physCursor, pl.depth > 0, pp.depth > 0 else {
            return full(path: path)
        }
        let folded = PathCanonicalizer.fold(name)
        let lexC = pathGuard.advance(pl, foldedComponent: folded)
        let physC = pathGuard.advance(pp, foldedComponent: folded)
        let deep = lexC.depth > maxRoot && physC.depth > maxRoot
        let lexSettled = p.lex != .none || lexC.live.isEmpty
        let physSettled = p.phys != .none || physC.live.isEmpty
        guard deep, lexSettled, physSettled else { return full(path: path, lex: lexC, phys: physC) }
        var s = State(lex: p.lex, phys: p.phys, lexCursor: lexC, physCursor: physC)
        if s.lex == .none || s.phys == .none {
            let hit: Bool
            if let c = nameCache[name] { hit = c } else { hit = pathGuard.matchesBasename(name); nameCache[name] = hit }
            if hit {
                if s.lex == .none { s.lex = .protected }
                if s.phys == .none { s.phys = .protected }
            }
        }
        return (s.flags, s)
    }

    /// The reference computation from the keys (also used by the differential tests).
    func full(path: String, lex: Cursor? = nil, phys: Cursor? = nil) -> (flags: NodeFlags, state: State) {
        let suffix = String(path.utf8.dropFirst(rootPrefixLen)) ?? ""
        let lexKey = PathCanonicalizer.key(path)
        let physKey = PathCanonicalizer.key(physicalBase + suffix)
        var s = State(lex: pathGuard.indexKind(forKey: lexKey), phys: pathGuard.indexKind(forKey: physKey))
        if enabled {
            s.lexCursor = lex ?? pathGuard.anchoredCursor(forKey: lexKey.components)
            s.physCursor = phys ?? pathGuard.anchoredCursor(forKey: physKey.components)
        }
        return (s.flags, s)
    }
}
