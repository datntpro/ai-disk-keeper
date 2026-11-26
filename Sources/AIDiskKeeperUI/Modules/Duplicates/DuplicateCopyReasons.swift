import DiskKeeperCore
import Foundation

/// Why a copy looks like the spare one (or why the keeper was kept). Pure: the view turns these into chips.
enum CopyReason: Equatable {
    case cloneOfKept
    case partlyShared
    case hardLinks(Int)
    case copyInName
    case inDownloads
    case onDesktop
    case inOldFolder
    case added(Date)
    case keeperRule(KeeperRule)
    case keeperInGit
    case keeperManual
}

enum DuplicateCopyReasons {
    static let maxChips = 3

    private static let oldFolderNames: Set<String> = ["old", "backup", "bak", "archive"]
    private static let copyName = try! NSRegularExpression(
        pattern: #"( copy( \d+)?| \(\d+\)| - copy|_copy|-\d+| bản sao( \d+)?)$"#, options: [.caseInsensitive])

    /// Chips for one row, most important first, at most ``maxChips``.
    static func reasons(for member: DuplicateMember, in group: DuplicateGroup, rule: KeeperRule, isManualKeeper: Bool,
                        home: String) -> [CopyReason] {
        var out: [CopyReason] = []
        if member.path == group.keeper.path {
            if isManualKeeper { out.append(.keeperManual) } else { out.append(.keeperRule(rule)) }
            if member.isInGitRepo, isManualKeeper || rule != .insideGitRepo { out.append(.keeperInGit) }
            if !member.otherLinkPaths.isEmpty { out.append(.hardLinks(member.otherLinkPaths.count)) }
            return Array(out.prefix(maxChips))
        }
        if member.sharesAllStorage { out.append(.cloneOfKept) }
        else if member.sharesStorage { out.append(.partlyShared) }
        if !member.otherLinkPaths.isEmpty { out.append(.hardLinks(member.otherLinkPaths.count)) }
        if hasCopyInName(member.path) { out.append(.copyInName) }
        if isIn(member.path, home + "/Downloads") { out.append(.inDownloads) }
        if isIn(member.path, home + "/Desktop") { out.append(.onDesktop) }
        if inOldFolder(member.path, home: home) { out.append(.inOldFolder) }
        let keeperDate = effective(group.keeper), date = effective(member)
        if date > keeperDate { out.append(.added(date)) }
        return Array(out.prefix(maxChips))
    }

    /// The file stem ends like a Finder or app copy ("report copy 2", "report (1)", "report bản sao").
    static func hasCopyInName(_ path: String) -> Bool {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let range = NSRange(stem.startIndex..., in: stem)
        return copyName.firstMatch(in: stem, options: [], range: range) != nil
    }

    private static func isIn(_ path: String, _ folder: String) -> Bool { path.hasPrefix(folder + "/") }

    private static func inOldFolder(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let below = path.dropFirst(home.count + 1).split(separator: "/").dropLast()
        return below.contains { oldFolderNames.contains($0.lowercased()) }
    }

    private static func effective(_ m: DuplicateMember) -> Date {
        m.created.timeIntervalSince1970 > 0 ? m.created : m.modified
    }
}
