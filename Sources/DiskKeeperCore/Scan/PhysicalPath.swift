import Foundation

/// Physical identity of an item path: the resolved parent directory plus the leaf (an item is never a symlink,
/// so the leaf needs no resolving). Falls back to the lexical path when the parent can't be resolved. Used to
/// detect overlaps that go through a symlinked parent.
enum PhysicalPath {
    static func of(_ path: String, resolver: any PathResolving, cache: inout [String: String]) -> String {
        let comps = PathNormalization.components(path)
        guard let leaf = comps.last else { return path }
        let parent = "/" + comps.dropLast().joined(separator: "/")
        let resolved: String
        if let hit = cache[parent] {
            resolved = hit
        } else {
            if case .resolved(let r) = resolver.resolve(parent), PathNormalization.isAbsolute(r) {
                resolved = PathNormalization.lexical(r)
            } else {
                resolved = parent
            }
            cache[parent] = resolved
        }
        return (resolved == "/" ? "" : resolved) + "/" + leaf
    }
}

/// Serializes `PhysicalPath` lookups (with a parent cache) off the engine actor, so resolving never blocks
/// item acceptance.
actor PhysicalPathResolver {
    private let resolver: any PathResolving = SystemPathResolver()
    private var cache: [String: String] = [:]
    func physical(_ path: String) -> String { PhysicalPath.of(path, resolver: resolver, cache: &cache) }
}
