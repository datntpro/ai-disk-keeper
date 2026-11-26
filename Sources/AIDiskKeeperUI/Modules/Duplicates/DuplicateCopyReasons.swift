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
    /// Unambiguous copy markers. A bare `-N` is not here: it only counts when a sibling without it exists.
    private static let copyName = try! NSRegularExpression(
        pattern: #"( copy( \d+)?| \(\d+\)| - copy|_copy| [2-9]| bản sao( \d+)?)$"#, options: [.caseInsensitive])
    private static let dashNumber = try! NSRegularExpression(pattern: #"-\d+$"#)

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
        // Derived from the current keeper on every call (never stored): the member shares everything, or the keeper
        // does and this member shares storage with it.
        if member.sharesAllStorage || (group.keeper.sharesAllStorage && member.sharesStorage) { out.append(.cloneOfKept) }
        else if member.sharesStorage { out.append(.partlyShared) }
        if !member.otherLinkPaths.isEmpty { out.append(.hardLinks(member.otherLinkPaths.count)) }
        if hasCopyInName(member.path, siblingPaths: group.members.map(\.path)) { out.append(.copyInName) }
        if isIn(member.path, home + "/Downloads") { out.append(.inDownloads) }
        if isIn(member.path, home + "/Desktop") { out.append(.onDesktop) }
        if inOldFolder(member.path, home: home) { out.append(.inOldFolder) }
        let keeperDate = effective(group.keeper), date = effective(member)
        if date > keeperDate { out.append(.added(date)) }
        return Array(out.prefix(maxChips))
    }

    /// The file stem ends like a Finder or app copy ("report copy 2", "report (1)", "report 2", "report bản sao").
    /// `invoice-2` counts only when `siblingPaths` holds `invoice` with the same extension; `invoice-2024` and
    /// `report-v2` never count on their own.
    static func hasCopyInName(_ path: String, siblingPaths: [String] = []) -> Bool {
        let name = path as NSString
        let ext = name.pathExtension
        let stem = (name.lastPathComponent as NSString).deletingPathExtension
        let range = NSRange(stem.startIndex..., in: stem)
        if copyName.firstMatch(in: stem, options: [], range: range) != nil { return true }
        guard let dash = dashNumber.firstMatch(in: stem, options: [], range: range), let r = Range(dash.range, in: stem)
        else { return false }
        let base = String(stem[..<r.lowerBound])
        guard !base.isEmpty else { return false }
        return siblingPaths.contains { other in
            let o = other as NSString
            return o.pathExtension == ext && (o.lastPathComponent as NSString).deletingPathExtension == base
        }
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
