import Darwin
import Foundation

/// Large, long-unopened files from the disk index. Read-only: no content is read, nothing is hashed, iCloud-only
/// files are never touched. Every item is tier Review (these are the user's own files). See docs/large-files.md.
public struct LargeFileScanner: Scanner {
    public let id = "large-files"
    private let options: LargeFileOptions
    private let lastOpened: any LastOpenedProviding
    private let appNames: any InstalledAppNamesProviding
    private let tree: @Sendable () async throws -> DiskTree
    /// TEST-ONLY.
    var _cloneProbe: (@Sendable (String) -> CloneInfo)?

    public init(options: LargeFileOptions, lastOpened: any LastOpenedProviding, appNames: any InstalledAppNamesProviding,
                tree: @escaping @Sendable () async throws -> DiskTree) {
        self.options = options
        self.lastOpened = lastOpened
        self.appNames = appNames
        self.tree = tree
    }

    // MARK: Report

    private struct Candidate {
        let path: String
        let record: FileRecord
    }

    public func report(tree: DiskTree, now: Date = Date()) async throws -> LargeFileReport {
        var stats = LargeFileSkipStats()
        try Task.checkCancellation()
        let candidates = candidates(in: tree, stats: &stats)
        let apps = appNames.names()
        let downloads = PathCanonicalizer.key(options.scopeRoot + "/Downloads").components
        var files: [LargeFile] = []
        for c in candidates {
            try Task.checkCancellation()
            let r = c.record
            var st = stat()
            guard lstat(c.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                  st.st_dev == r.device, st.st_ino == r.inode else { stats.changed += 1; continue }
            guard let dates = lastOpened.dates(for: c.path) else { stats.changed += 1; continue }
            let (opened, source) = dates.lastOpened
            let info = _cloneProbe?(c.path) ?? CloneProbe.probe(c.path)
            var reclaimable: Int64?
            var shares = r.linkCount > 1
            var sharesAll = false
            if case .known(_, _, let privateBytes, let sharesAllBlocks, _) = info {
                reclaimable = privateBytes
                sharesAll = sharesAllBlocks
                if sharesAllBlocks || privateBytes < r.allocatedBytes { shares = true }
            } else {
                shares = true
            }
            let name = (c.path as NSString).lastPathComponent
            let kind = LargeFileKind.classify(fileName: name)
            var match: String?
            let inDownloads = Self.hasPrefix(PathCanonicalizer.key(c.path).components, downloads)
            if kind == .diskImageOrInstaller || (inDownloads && name.lowercased().hasSuffix(".zip")) {
                match = ApplicationsFolderNames.match(stem: (name as NSString).deletingPathExtension, in: apps)
            }
            files.append(LargeFile(path: c.path, logicalBytes: r.logicalBytes, allocatedBytes: r.allocatedBytes,
                                   reclaimableBytes: reclaimable, kind: kind, dates: dates, lastOpened: opened,
                                   lastOpenedSource: source, installedAppMatch: match, sharesStorage: shares,
                                   sharesAllStorage: sharesAll, linkCount: r.linkCount))
        }
        files.sort { $0.allocatedBytes != $1.allocatedBytes ? $0.allocatedBytes > $1.allocatedBytes : $0.path < $1.path }
        return LargeFileReport(files: files, skipped: stats, warnings: [])
    }

    private func candidates(in tree: DiskTree, stats: inout LargeFileSkipStats) -> [Candidate] {
        let scopeKey = PathCanonicalizer.key(options.scopeRoot).components
        let excluded = options.excludedRoots.map { PathCanonicalizer.key($0).components }
        let blocked: NodeFlags = [.protected, .outsideCleanableRoots, .nonUTF8Name]
        var out: [Candidate] = []
        for r in tree.fileRecords where r.logicalBytes >= options.minimumBytes {
            // A record folded into its directory by the node budget has no path of its own.
            let nodeFlags = NodeFlags(rawValue: tree.flagBits[Int(r.node.raw)])
            guard nodeFlags.contains(.file) else { stats.folded += 1; continue }
            if r.flags.contains(.dataless) || nodeFlags.contains(.dataless) { stats.dataless += 1; continue }
            if r.flags.contains(.hardlinkRepeat) { stats.hardLinkRepeat += 1; continue }
            if !r.flags.isDisjoint(with: blocked) || !nodeFlags.isDisjoint(with: blocked) { stats.protected += 1; continue }
            let path = tree.path(of: r.node)
            let comps = PathCanonicalizer.key(path).components
            guard Self.hasPrefix(comps, scopeKey), !excluded.contains(where: { Self.hasPrefix(comps, $0) }) else {
                stats.outOfScope += 1; continue
            }
            if options.skipHiddenComponents, comps.dropFirst(scopeKey.count).contains(where: { $0.hasPrefix(".") }) {
                stats.outOfScope += 1; continue
            }
            out.append(Candidate(path: path, record: r))
        }
        return out
    }

    private static func hasPrefix(_ comps: [String], _ prefix: [String]) -> Bool {
        comps.count >= prefix.count && Array(comps[0..<prefix.count]) == prefix
    }

    // MARK: Care Scan adapter

    /// ``report(tree:now:)`` minus the files the path guard denies or another user owns: the same filter Care Scan
    /// applies, so the Large & Old screen and the Care Scan list agree.
    public func report(tree: DiskTree, context: ScanContext) async throws -> LargeFileReport {
        var report = try await report(tree: tree, now: context.now)
        var kept: [LargeFile] = []
        for file in report.files {
            try Task.checkCancellation()
            if context.pathGuard.check(file.path).denial != nil { report.skipped.guardDropped += 1; continue }
            var st = stat()
            if lstat(file.path, &st) == 0, st.st_uid != context.userID { report.skipped.ownerDropped += 1; continue }
            kept.append(file)
        }
        report.files = kept
        return report
    }

    public func scan(context: ScanContext, sink: ScanSink) async throws {
        let index = try await tree()
        try Task.checkCancellation()
        let report = try await report(tree: index, context: context)
        for w in report.warnings { await sink.warning(w) }
        var progress = ScannerProgress()
        progress.candidatesFound = report.files.count
        progress.guardDropped = report.skipped.guardDropped
        progress.ownerDropped = report.skipped.ownerDropped
        for file in report.files {
            try Task.checkCancellation()
            let item = Self.makeItem(file)
            progress.candidatesSized += 1
            progress.bytesFound += item.sizeAllocated
            await sink.item(item)
        }
        await sink.progress(progress)
    }

    /// Always Review; report-only (`.none`) when deleting would free nothing.
    public static func makeItem(_ f: LargeFile) -> ScanItem {
        let reportOnly = f.linkCount > 1 || f.sharesAllStorage
        var flags: Set<ItemFlag> = []
        if f.sharesStorage { flags.insert(.sharedStorage) }
        let explanation = reportOnly
            ? "This file shares all of its storage with another file (hard link or APFS clone). Deleting it frees almost no space."
            : "A large \(f.kind.rawValue) file you haven't opened since \(f.lastOpened.formatted(date: .abbreviated, time: .omitted)). Moving it to the Trash frees up to \(ByteCountFormatter.string(fromByteCount: f.reclaimableBytes ?? f.allocatedBytes, countStyle: .file)); you can put it back from the Trash."
        return ScanItem(url: URL(fileURLWithPath: f.path), displayName: f.name, tool: .files, category: .largeFile,
                        sizeAllocated: f.allocatedBytes, sizeLogical: f.logicalBytes, fileCount: 1,
                        lastModified: f.dates.modified, tier: .review, explanation: explanation,
                        ruleID: "large.\(f.kind.rawValue)", cleanupMethod: reportOnly ? CleanupMethod.none : .trash,
                        flags: flags)
    }
}
