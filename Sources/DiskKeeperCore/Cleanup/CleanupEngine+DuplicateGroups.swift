import Darwin
import Foundation

/// Keep-one invariant for duplicate groups (PLAN invariant 13). The check needs the whole selection, so it
/// lives in the engine and not in `ItemValidator`, which sees one item at a time. See docs/cleanup.md.
extension CleanupEngine {
    static func isDuplicateItem(_ item: ScanItem) -> Bool {
        item.category == .duplicate || (item.groupID?.hasPrefix("dup:") ?? false)
    }

    /// Plan time: attach the verified survivors, or block every selected member of the group.
    func applyKeepOne(items: [ScanItem], groups: [String: DuplicateGroup],
                      blockers: inout [[CleanupBlocker]], survivors: inout [Int: DuplicateSurvivorSet]) async {
        // Every plan item claims its path and everything below it, whatever its category: a survivor that
        // another item (or a folder item) would trash is not a survivor.
        let claimed = items.map { PathCanonicalizer.key($0.path) }
        var byGroup: [String: [Int]] = [:]
        for i in items.indices where Self.isDuplicateItem(items[i]) { byGroup[items[i].groupID ?? "", default: []].append(i) }
        for (groupID, indices) in byGroup.sorted(by: { $0.key < $1.key }) {
            guard let group = groups[groupID] else {
                for i in indices { blockers[i].append(.duplicateGroupUnknown(groupID: groupID)) }
                continue
            }
            let memberKeys = Set(group.members.map { PathCanonicalizer.key($0.path) })
            // An item that is not a member of its group (a link name, a stale path) cannot be reasoned about.
            let unknown = indices.filter { !memberKeys.contains(PathCanonicalizer.key(items[$0].path)) }
            for i in unknown { blockers[i].append(.duplicateGroupUnknown(groupID: groupID)) }
            let selected = Set(indices.map { PathCanonicalizer.key(items[$0].path) })
            // A forged group may list one inode under two paths: never accept the inode of a selected copy.
            let selectedInodes = Set(group.members.filter { selected.contains(PathCanonicalizer.key($0.path)) }
                .map { InodeKey(device: $0.device, inode: $0.inode) })
            let unselected = group.members.filter { m in
                let k = PathCanonicalizer.key(m.path)
                return !Self.isClaimed(k, by: claimed) && !selectedInodes.contains(InodeKey(device: m.device, inode: m.inode))
            }
            var verified: [SurvivorFingerprint] = []
            for m in unselected where await Self.survivorIsValid(
                path: m.path, device: m.device, inode: m.inode, modified: m.modified,
                logicalBytes: group.logicalBytes, partialDigest: group.partialDigest) {
                verified.append(SurvivorFingerprint(path: m.path, device: m.device, inode: m.inode, modified: m.modified))
            }
            if verified.isEmpty {
                for i in indices where !unknown.contains(i) { blockers[i].append(.wouldRemoveAllCopies(groupID: groupID)) }
                continue
            }
            let set = DuplicateSurvivorSet(groupID: groupID, logicalBytes: group.logicalBytes,
                                           partialDigest: group.partialDigest, survivors: verified)
            for i in indices where !unknown.contains(i) { survivors[i] = set }
        }
    }

    /// Execute time: re-verify the survivors right before the move. `nil` = go ahead.
    /// `claimed`: the keys of every entry of the plan (any category); `trashedKeys` is a subset, kept for clarity.
    func keepOneGate(_ entry: CleanupPlanEntry, trashedKeys: Set<PathKey>, claimed: [PathKey]) async -> CleanupBlocker? {
        guard Self.isDuplicateItem(entry.item) else { return nil }
        let groupID = entry.item.groupID ?? ""
        guard let set = entry.survivors, set.groupID == groupID else { return .duplicateGroupUnknown(groupID: groupID) }
        for s in set.survivors {
            let key = PathCanonicalizer.key(s.path)
            if trashedKeys.contains(key) || Self.isClaimed(key, by: claimed) { continue }
            if let fp = entry.fingerprint, fp.device == s.device, fp.inode == s.inode { continue }
            if await Self.survivorIsValid(path: s.path, device: s.device, inode: s.inode, modified: s.modified,
                                          logicalBytes: set.logicalBytes, partialDigest: set.partialDigest) {
                return nil
            }
        }
        return .survivorChanged(groupID: groupID)
    }

    /// True when `key` equals, or lies below, the key of any claiming plan item.
    static func isClaimed(_ key: PathKey, by claimed: [PathKey]) -> Bool {
        claimed.contains { c in
            c.components.count <= key.components.count && Array(key.components.prefix(c.components.count)) == c.components
        }
    }

    /// lstat identity + regular file + size + mtime (±2 s) + partial digest (128 KiB read). A full re-hash is
    /// deliberately not done here (cost); see docs/duplicates.md for the trade-off.
    static func survivorIsValid(path: String, device: Int32, inode: UInt64, modified: Date,
                                logicalBytes: Int64, partialDigest: String) async -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              Int32(truncatingIfNeeded: st.st_dev) == device, UInt64(st.st_ino) == inode,
              Int64(st.st_size) == logicalBytes else { return false }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        guard abs(mtime - modified.timeIntervalSince1970) <= 2 else { return false }
        let identity = FileIdentity(device: device, inode: inode, size: logicalBytes)
        guard let outcome = try? await ContentHasher.partialDigest(path: path, identity: identity),
              case .digest(let digest, _) = outcome else { return false }
        return digest == partialDigest
    }
}
