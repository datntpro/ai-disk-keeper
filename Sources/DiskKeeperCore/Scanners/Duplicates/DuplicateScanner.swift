import Darwin
import Foundation

/// Adapts ``DuplicateFinder`` to the scanner protocol: one `ScanItem` per member, the suggested keeper
/// included, so a UI can swap the keeper. Items are always tier Review; nothing here is pre-selected.
///
/// Run it in its own `ScanEngine` run, or call ``report(tree:progress:)`` directly. Mixing it with rule
/// scanners makes `PathClaimSet` drop members that sit inside claimed items (a worktree, say). Dropping is
/// safe (survivors are only counted from what the UI holds) but confusing.
public struct DuplicateScanner: Scanner {
    public let id = "duplicates"
    private let options: DuplicateOptions
    private let tree: @Sendable () async throws -> DiskTree

    public init(options: DuplicateOptions, tree: @escaping @Sendable () async throws -> DiskTree) {
        self.options = options
        self.tree = tree
    }

    /// The finder's report without the scanner plumbing.
    public func report(tree: DiskTree, progress: (@Sendable (DuplicateStats) -> Void)? = nil) async throws -> DuplicateReport {
        try await DuplicateFinder(options: options).find(in: tree, progress: progress)
    }

    public func scan(context: ScanContext, sink: ScanSink) async throws {
        let index = try await tree()
        try Task.checkCancellation()
        let report = try await report(tree: index)
        for w in report.warnings { await sink.warning(w) }

        var progress = ScannerProgress()
        progress.candidatesFound = report.groups.reduce(0) { $0 + $1.members.count }
        await sink.progress(progress)

        let built = Self.itemsAndDrops(for: report, rule: options.keeperRule, pathGuard: context.pathGuard,
                                       userID: context.userID)
        progress.guardDropped = built.guardDropped
        progress.ownerDropped = built.ownerDropped
        for group in report.groups {
            try Task.checkCancellation()
            guard let items = built.items[group.id] else { continue }
            for item in items {
                progress.candidatesSized += 1
                progress.bytesFound += item.sizeAllocated
                await sink.item(item)
            }
            await sink.progress(progress)
        }
    }

    /// One `ScanItem` per member (the keeper included, flagged `suggestedKeeper`), keyed by group id. Members the
    /// scan guard denies or that another user owns are dropped; a group left with fewer than two members is
    /// dropped whole. The UI calls this again after it re-orders a group, so the keeper flag follows.
    public static func items(for report: DuplicateReport, rule: KeeperRule, pathGuard: ScanGuard,
                             userID: uid_t) -> [String: [ScanItem]] {
        itemsAndDrops(for: report, rule: rule, pathGuard: pathGuard, userID: userID).items
    }

    private static func itemsAndDrops(for report: DuplicateReport, rule: KeeperRule, pathGuard: ScanGuard,
                                      userID: uid_t) -> (items: [String: [ScanItem]], guardDropped: Int, ownerDropped: Int) {
        var out: [String: [ScanItem]] = [:]
        var guardDropped = 0, ownerDropped = 0
        for group in report.groups {
            var allowed: [DuplicateMember] = []
            for m in group.members {
                if pathGuard.check(m.path).denial != nil { guardDropped += 1; continue }
                var st = stat()
                if lstat(m.path, &st) == 0, st.st_uid != userID { ownerDropped += 1; continue }
                allowed.append(m)
            }
            guard allowed.count >= 2 else { continue }
            let keeper = group.keeper
            out[group.id] = allowed.map { makeItem($0, group: group, keeper: keeper, rule: rule) }
        }
        return (out, guardDropped, ownerDropped)
    }

    /// The `ScanItem` for one member of `group`. `keeper` decides the `suggestedKeeper` flag and the explanation.
    public static func makeItem(_ m: DuplicateMember, group: DuplicateGroup, keeper: DuplicateMember,
                         rule: KeeperRule) -> ScanItem {
        var flags: Set<ItemFlag> = []
        var method: CleanupMethod = .trash
        let isKeeper = m.path == keeper.path
        if isKeeper { flags.insert(.suggestedKeeper) }
        if m.sharesStorage { flags.insert(.sharedStorage) }
        var explanation: String
        if m.sharesAllStorage {
            method = .none
            flags.insert(.sharedStorage)
            explanation = "This copy shares all of its storage with another file (APFS clone or hard link). Deleting it frees almost no space."
        } else if isKeeper {
            let others = group.members.count - 1
            let why: String = switch rule {
            case .oldest: "oldest copy"
            case .insideGitRepo: "copy inside a git repository"
            case .shortestPath: "copy with the shortest path"
            }
            explanation = "Identical to \(others) other file\(others == 1 ? "" : "s") (SHA-256). Suggested to keep: \(why)."
        } else {
            explanation = "Identical to \((keeper.path as NSString).lastPathComponent) (SHA-256 checked). Deleting this copy keeps \(keeper.path)."
        }
        return ScanItem(url: URL(fileURLWithPath: m.path),
                        displayName: (m.path as NSString).lastPathComponent,
                        tool: .files, category: .duplicate,
                        sizeAllocated: m.allocatedBytes, sizeLogical: m.logicalBytes, fileCount: 1,
                        lastModified: m.modified, tier: .review, explanation: explanation,
                        ruleID: "duplicates.copy", cleanupMethod: method, flags: flags, groupID: group.id)
    }
}
