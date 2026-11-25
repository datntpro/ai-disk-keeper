import Foundation

/// Set of claimed paths compared by `PathCanonicalizer.key` (alias- and case-folded components).
/// `claim` fails if the path equals, is inside, or contains an already-claimed path.
/// Implemented as a trie of folded components (an index-based value type): lookup is O(depth).
struct PathClaimSet: Sendable {
    enum Conflict: Equatable { case equal(String), inside(String), contains(String) }   // payload = claimed path

    private struct Node: Sendable {
        var children: [String: Int] = [:]
        var claimed: String?
    }

    private var nodes: [Node] = [Node()]

    /// nil = claimed.
    mutating func claim(_ path: String) -> Conflict? {
        var index = 0
        for component in PathCanonicalizer.key(path).components {
            if let claimed = nodes[index].claimed { return .inside(claimed) }
            if let next = nodes[index].children[component] {
                index = next
            } else {
                nodes.append(Node())
                nodes[index].children[component] = nodes.count - 1
                index = nodes.count - 1
            }
        }
        if let claimed = nodes[index].claimed { return .equal(claimed) }
        if let below = firstClaimed(below: index) { return .contains(below) }
        nodes[index].claimed = path
        return nil
    }

    private func firstClaimed(below index: Int) -> String? {
        for (_, child) in nodes[index].children.sorted(by: { $0.key < $1.key }) {
            if let c = nodes[child].claimed { return c }
            if let c = firstClaimed(below: child) { return c }
        }
        return nil
    }
}
