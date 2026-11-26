import Foundation

extension DuplicateGroup {
    /// The same members in keeper order for `rule` (`members[0]` is the keeper), using the finder's own
    /// comparator. `id`, digests and sizes don't change, so `reclaimableBytes` follows the new keeper.
    public func reordered(by rule: KeeperRule) -> DuplicateGroup {
        // The scope root only matters to the finder's git lookup, which is already baked into each member.
        DuplicateGroup(digest: digest, partialDigest: partialDigest, logicalBytes: logicalBytes,
                       members: DuplicateFinder.keeperOrder(members, rule: rule, scopeRoot: ""))
    }

    /// A manual keeper: `path` first, the other members in their current order. `nil` if `path` is not a member.
    public func reordered(keeper path: String) -> DuplicateGroup? {
        guard let index = members.firstIndex(where: { $0.path == path }) else { return nil }
        guard index != 0 else { return self }
        var next = members
        let chosen = next.remove(at: index)
        next.insert(chosen, at: 0)
        return DuplicateGroup(digest: digest, partialDigest: partialDigest, logicalBytes: logicalBytes, members: next)
    }
}
