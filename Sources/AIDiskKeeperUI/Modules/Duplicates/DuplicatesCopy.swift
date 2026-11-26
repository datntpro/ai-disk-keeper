import DiskKeeperCore
import Foundation

/// Localized text for the Duplicates screen. Core's English explanations are never shown: they are built here.
enum DuplicatesCopy {
    static func reason(_ r: CopyReason) -> String {
        switch r {
        case .cloneOfKept: loc("dup.reason.cloneOfKept", "clone of the kept copy — deleting frees nothing")
        case .partlyShared: loc("dup.reason.partlyShared", "shares some storage — may free less")
        case .hardLinks(let n): loc("dup.reason.hardLinks", "\(Formatting.count(n)) other names (hard links)")
        case .copyInName: loc("dup.reason.copyInName", "“copy” in name")
        case .inDownloads: loc("dup.reason.inDownloads", "in Downloads")
        case .onDesktop: loc("dup.reason.onDesktop", "on Desktop")
        case .inOldFolder: loc("dup.reason.oldFolder", "in an old/backup folder")
        case .added(let d): loc("dup.reason.added", "added \(Formatting.relative(d))")
        case .keeperRule(let rule): keeperRule(rule)
        case .keeperInGit: loc("dup.keeper.git", "in a git repo")
        case .keeperManual: loc("dup.keeper.manual", "chosen by you")
        }
    }

    private static func keeperRule(_ rule: KeeperRule) -> String {
        switch rule {
        case .oldest: loc("dup.keeper.oldest", "oldest")
        case .insideGitRepo: loc("dup.keeper.git", "in a git repo")
        case .shortestPath: loc("dup.keeper.shortest", "shortest path")
        }
    }

    static func ruleName(_ rule: KeeperRule) -> String {
        switch rule {
        case .oldest: loc("dup.rule.oldest", "Oldest")
        case .insideGitRepo: loc("dup.rule.git", "In a git repo")
        case .shortestPath: loc("dup.rule.shortest", "Shortest path")
        }
    }

    static func threshold(_ bytes: Int64) -> String {
        loc("dup.threshold", "\(Formatting.bytes(bytes)) or larger")
    }

    static func subtitle(groups: Int, bytes: Int64) -> String {
        groups == 1 ? loc("dup.subtitleOne", "1 group · \(Formatting.bytes(bytes)) in extra copies")
                    : loc("dup.subtitle", "\(Formatting.count(groups)) groups · \(Formatting.bytes(bytes)) in extra copies")
    }

    static func selectedCount(_ n: Int) -> String {
        n == 1 ? loc("dup.selectedCountOne", "1 copy selected · each group keeps one")
               : loc("dup.selectedCount", "\(Formatting.count(n)) copies selected · each group keeps one")
    }

    static func progress(done: Int, total: Int) -> String {
        loc("dup.progress", "Comparing files… \(Formatting.count(done)) of \(Formatting.count(total)) checked")
    }

    static func explanation(for member: DuplicateMember, in group: DuplicateGroup) -> String {
        let keeper = group.keeper
        if member.path == keeper.path {
            return loc("dup.explain.keeper", "This is the copy that stays. The other \(Formatting.count(group.members.count - 1)) copies are identical (SHA-256 checked).")
        }
        if member.sharesAllStorage {
            return loc("dup.explain.clone", "This copy shares all of its storage with another file (APFS clone or hard link). Deleting it frees nothing, so it can't be selected.")
        }
        return loc("dup.explain.copy", "Identical to \((keeper.path as NSString).lastPathComponent) (SHA-256 checked). Moving this copy to the Trash keeps \(keeper.path).")
    }

    static func a11yRow(member: DuplicateMember, group: DuplicateGroup, selected: Bool) -> String {
        let name = (member.path as NSString).lastPathComponent
        let folder = ((member.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let state: String
        if member.path == group.keeper.path {
            state = loc("dup.a11y.kept", "kept copy")
        } else if member.sharesAllStorage {
            state = loc("dup.a11y.clone", "copy, shares storage, can't be selected")
        } else {
            state = selected ? loc("dup.a11y.copySelected", "copy, selected") : loc("dup.a11y.copy", "copy, not selected")
        }
        return loc("dup.a11y.row", "\(name) in \(folder), \(Formatting.bytes(member.allocatedBytes)), \(state)")
    }
}
