import DiskKeeperCore
import Foundation

/// What a duplicate copy is worth when it is deleted. Certain bytes count only copies that own their storage.
struct DuplicateSavings: Equatable {
    var certainBytes: Int64 = 0
    /// At least one selected copy shares storage or has unknown size, so the real number may be lower.
    var mayFreeLess = false

    static let zero = DuplicateSavings()

    /// Bytes a member is certain to free: shared copies and unknown sizes count 0.
    static func certain(_ m: DuplicateMember) -> Int64 { m.sharesStorage ? 0 : (m.reclaimableBytes ?? 0) }
    static func isUncertain(_ m: DuplicateMember) -> Bool { m.sharesStorage || m.reclaimableBytes == nil }
}

/// The keep-one-aware selection of duplicate copies. The UI can't ask for the impossible: the keeper is never
/// selectable, a report-only copy is never selectable, and there is no "select all" anywhere. The cleanup engine
/// enforces the same rule again at plan and execute time.
struct DuplicateSelection: Equatable {
    private(set) var selected: [String: Set<String>] = [:]
    private var contribution: [String: (bytes: Int64, uncertain: Int)] = [:]
    private var totalBytes: Int64 = 0
    private var totalUncertain = 0

    var count: Int { selected.values.reduce(0) { $0 + $1.count } }
    var isEmpty: Bool { selected.isEmpty }
    var savings: DuplicateSavings { DuplicateSavings(certainBytes: totalBytes, mayFreeLess: totalUncertain > 0) }

    static func == (l: DuplicateSelection, r: DuplicateSelection) -> Bool { l.selected == r.selected }

    func isSelected(_ path: String, in groupID: String) -> Bool { selected[groupID]?.contains(path) ?? false }
    func selectedPaths(in groupID: String) -> Set<String> { selected[groupID] ?? [] }

    /// `actionable` is false for report-only members (full clones, `cleanupMethod == .none`).
    func canSelect(_ path: String, in group: DuplicateGroup, actionable: Bool) -> Bool {
        guard actionable, path != group.keeper.path, group.members.contains(where: { $0.path == path }) else { return false }
        // Belt and braces: after adding it, at least one member of the group must stay unselected.
        var after = selected[group.id] ?? []
        after.insert(path)
        return group.members.contains { !after.contains($0.path) }
    }

    /// Flips the member. Returns false (and changes nothing) when `canSelect` refuses and it isn't selected.
    @discardableResult
    mutating func toggle(_ path: String, in group: DuplicateGroup, actionable: Bool) -> Bool {
        var paths = selected[group.id] ?? []
        if paths.contains(path) {
            paths.remove(path)
        } else {
            guard canSelect(path, in: group, actionable: actionable) else { return false }
            paths.insert(path)
        }
        set(paths, for: group)
        return true
    }

    /// The group's keeper or members changed: drop what is no longer selectable (the new keeper first of all).
    mutating func groupChanged(_ group: DuplicateGroup) {
        guard let paths = selected[group.id] else { return }
        let memberPaths = Set(group.members.map(\.path))
        var kept = paths.intersection(memberPaths)
        kept.remove(group.keeper.path)
        if kept.count >= group.members.count { kept = [] }   // unreachable by construction; fail closed
        set(kept, for: group)
    }

    mutating func removeGroup(_ id: String) {
        guard let old = contribution.removeValue(forKey: id) else { selected[id] = nil; return }
        totalBytes -= old.bytes
        totalUncertain -= old.uncertain
        selected[id] = nil
    }

    mutating func clear() { self = DuplicateSelection() }

    private mutating func set(_ paths: Set<String>, for group: DuplicateGroup) {
        let old = contribution[group.id] ?? (0, 0)
        var bytes: Int64 = 0, uncertain = 0
        if paths.isEmpty {
            selected[group.id] = nil
            contribution[group.id] = nil
        } else {
            for m in group.members where paths.contains(m.path) {
                bytes += DuplicateSavings.certain(m)
                if DuplicateSavings.isUncertain(m) { uncertain += 1 }
            }
            selected[group.id] = paths
            contribution[group.id] = (bytes, uncertain)
        }
        totalBytes += bytes - old.bytes
        totalUncertain += uncertain - old.uncertain
    }
}
