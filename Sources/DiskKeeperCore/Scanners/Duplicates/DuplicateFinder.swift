import Darwin
import Foundation

/// Finds byte-identical files in a ``DiskTree``: size buckets → partial hash → full hash → clone/link
/// analysis → keeper order. Read-only; hashing never leaves a trace (no cache fill, no atime writes we cause,
/// no dataless materialization). See docs/duplicates.md.
public struct DuplicateFinder: Sendable {
    public let options: DuplicateOptions

    public init(options: DuplicateOptions) { self.options = options }

    private struct Candidate: Sendable {
        let path: String
        let key: InodeKey
        let logical: Int64
        var allocated: Int64
        let created: Date
        let modified: Date
        var otherLinks: [String] = []
        var identity: FileIdentity { FileIdentity(device: key.device, inode: key.inode, size: logical) }
    }

    public func find(in tree: DiskTree, progress: (@Sendable (DuplicateStats) -> Void)? = nil) async throws -> DuplicateReport {
        let clock = ContinuousClock()
        let started = clock.now
        var stats = DuplicateStats()
        var warnings: [ScanWarning] = []
        var unreadableWarned = 0
        try Task.checkCancellation()

        // 1. Candidates from the index.
        let buckets = candidateBuckets(tree, stats: &stats)
        stats.sizeBuckets = buckets.count
        stats.candidates = buckets.reduce(0) { $0 + $1.count }

        func note(_ outcome: HashOutcome, path: String) {
            switch outcome {
            case .digest: break
            case .changed: stats.skippedChanged += 1
            case .dataless: stats.skippedDataless += 1
            case .unreadable(let code):
                stats.skippedUnreadable += 1
                if unreadableWarned % 50 == 0 {
                    warnings.append(ScanWarning(
                        kind: code == EPERM ? .needsFullDiskAccess : .permissionDenied, path: path,
                        message: "Couldn't read some files while comparing duplicates.", code: .pathError(errno: code)))
                }
                unreadableWarned += 1
            }
        }

        // 2. Partial hash.
        let partialInput = buckets.flatMap { $0 }
        let partial = try await hashAll(partialInput, full: false) { index, outcome in
            stats.partialHashed += 1
            if case .digest(_, let n) = outcome { stats.bytesRead += n }
            note(outcome, path: partialInput[index].path)
            progress?(stats)
        }
        var byPartial: [String: [(Candidate, String)]] = [:]
        for (i, c) in partialInput.enumerated() {
            if case .digest(let h, _)? = partial[i] { byPartial["\(c.logical)|\(h)", default: []].append((c, h)) }
        }

        // 3. Full hash.
        var fullInput: [(Candidate, String)] = []
        for key in byPartial.keys.sorted() {
            if let g = byPartial[key], g.count >= 2 { fullInput += g }
        }
        let full = try await hashAll(fullInput.map(\.0), full: true) { index, outcome in
            stats.fullHashed += 1
            if case .digest(_, let n) = outcome { stats.bytesRead += n }
            note(outcome, path: fullInput[index].0.path)
            progress?(stats)
        }
        var byFull: [String: (partial: String, members: [Candidate])] = [:]
        for (i, entry) in fullInput.enumerated() {
            if case .digest(let h, _)? = full[i] {
                let k = "\(entry.0.logical)|\(h)"
                byFull[k, default: (entry.1, [])].members.append(entry.0)
            }
        }

        // 4–6. Clone info, keeper order, drop groups that waste nothing.
        var gitCache: [String: Bool] = [:]
        let scopeKey = PathCanonicalizer.key(options.scopeRoot).components
        var groups: [DuplicateGroup] = []
        for k in byFull.keys.sorted() {
            try Task.checkCancellation()
            guard let entry = byFull[k], entry.members.count >= 2 else { continue }
            let digest = String(k.split(separator: "|", maxSplits: 1)[1])
            var members: [DuplicateMember] = []
            for c in entry.members {
                let info = options._cloneProbe?(c.path) ?? CloneInfo.probe(c.path)
                members.append(makeMember(c, info: info, git: inGitRepo(c.path, scopeKey: scopeKey, cache: &gitCache)))
            }
            members.sort { precedes($0, $1) }
            if members.dropFirst().allSatisfy(\.sharesAllStorage) { stats.groupsDroppedAllShared += 1; continue }
            groups.append(DuplicateGroup(digest: digest, partialDigest: entry.partial,
                                         logicalBytes: members[0].logicalBytes, members: members))
        }
        groups.sort { l, r in
            let a = l.reclaimableBytes, b = r.reclaimableBytes
            return a != b ? a > b : l.id < r.id
        }
        stats.duration = clock.now - started
        return DuplicateReport(groups: groups, stats: stats, warnings: warnings)
    }

    // MARK: Candidates

    private func candidateBuckets(_ tree: DiskTree, stats: inout DuplicateStats) -> [[Candidate]] {
        let scopeKey = PathCanonicalizer.key(options.scopeRoot).components
        let excluded = options.excludedRoots.map { PathCanonicalizer.key($0).components }
        let skipNames = Set(options.skipComponentNames.map(PathCanonicalizer.fold))
        let blocked: NodeFlags = [.dataless, .protected, .outsideCleanableRoots]

        var allLinks: [InodeKey: [String]] = [:]
        var byInode: [InodeKey: Candidate] = [:]
        for r in tree.fileRecords where r.logicalBytes >= options.minimumLogicalBytes {
            // A record folded into its directory by the node budget has no path of its own.
            guard NodeFlags(rawValue: tree.flagBits[Int(r.node.raw)]).contains(.file) else { continue }
            let key = InodeKey(device: r.device, inode: r.inode)
            let path = tree.path(of: r.node)
            if r.linkCount > 1 { allLinks[key, default: []].append(path) }
            if r.flags.contains(.dataless) { stats.skippedDataless += 1; continue }
            if !r.flags.isDisjoint(with: blocked) { continue }
            let comps = PathCanonicalizer.key(path).components
            guard Self.hasPrefix(comps, scopeKey) else { continue }
            if excluded.contains(where: { Self.hasPrefix(comps, $0) }) { continue }
            let below = comps.dropFirst(scopeKey.count)
            if options.skipHiddenComponents, below.contains(where: { $0.hasPrefix(".") }) { continue }
            if below.contains(where: { skipNames.contains($0) }) { continue }
            if options._datalessOverride?(path) == true { stats.skippedDataless += 1; continue }
            if var existing = byInode[key] {
                existing.allocated = max(existing.allocated, r.allocatedBytes)
                if path < existing.path {
                    byInode[key] = Candidate(path: path, key: key, logical: r.logicalBytes, allocated: existing.allocated,
                                             created: r.created, modified: r.modified)
                } else {
                    byInode[key] = existing
                }
            } else {
                byInode[key] = Candidate(path: path, key: key, logical: r.logicalBytes, allocated: r.allocatedBytes,
                                         created: r.created, modified: r.modified)
            }
        }
        // The real (non-repeat) record carries the allocated bytes; take the largest over every name.
        for r in tree.fileRecords where r.allocatedBytes > 0 {
            let key = InodeKey(device: r.device, inode: r.inode)
            if var c = byInode[key], r.allocatedBytes > c.allocated { c.allocated = r.allocatedBytes; byInode[key] = c }
        }
        var byLogical: [Int64: [Candidate]] = [:]
        for var c in byInode.values {
            c.otherLinks = (allLinks[c.key] ?? []).filter { $0 != c.path }.sorted()
            byLogical[c.logical, default: []].append(c)
        }
        return byLogical.keys.sorted().compactMap { size in
            guard let list = byLogical[size], list.count >= 2 else { return nil }
            return list.sorted { $0.path < $1.path }
        }
    }

    private static func hasPrefix(_ comps: [String], _ prefix: [String]) -> Bool {
        comps.count >= prefix.count && Array(comps[0..<prefix.count]) == prefix
    }

    // MARK: Hashing

    /// Runs the hash jobs with a bounded window. Results by input index; `nil` when the job reported no digest.
    private func hashAll(_ items: [Candidate], full: Bool,
                         onResult: (Int, HashOutcome) -> Void) async throws -> [HashOutcome?] {
        var results = [HashOutcome?](repeating: nil, count: items.count)
        guard !items.isEmpty else { return results }
        let limiter = AsyncLimiter(limit: options.maxConcurrentHashes)
        let window = max(1, options.maxConcurrentHashes) * 2
        try await withThrowingTaskGroup(of: (Int, HashOutcome).self) { group in
            var next = 0
            func launch() {
                guard next < items.count else { return }
                let index = next, c = items[next]
                next += 1
                group.addTask {
                    try await limiter.acquire()
                    do {
                        let outcome = full ? try await ContentHasher.fullDigest(path: c.path, identity: c.identity)
                                           : try await ContentHasher.partialDigest(path: c.path, identity: c.identity)
                        await limiter.release()
                        return (index, outcome)
                    } catch {
                        await limiter.release()
                        throw error
                    }
                }
            }
            for _ in 0..<min(window, items.count) { launch() }
            while let (index, outcome) = try await group.next() {
                results[index] = outcome
                onResult(index, outcome)
                try Task.checkCancellation()
                launch()
            }
        }
        return results
    }

    // MARK: Members and keeper order

    private func makeMember(_ c: Candidate, info: CloneInfo, git: Bool) -> DuplicateMember {
        let reclaimable: Int64?
        var sharesAll = false
        var shares = !c.otherLinks.isEmpty
        switch info {
        case .unknown:
            reclaimable = nil
            shares = true
        case .known(_, _, let privateBytes, let sharesAllBlocks, _):
            reclaimable = privateBytes
            sharesAll = sharesAllBlocks
            if sharesAllBlocks || privateBytes < c.allocated { shares = true }
        }
        return DuplicateMember(path: c.path, device: c.key.device, inode: c.key.inode, otherLinkPaths: c.otherLinks,
                               logicalBytes: c.logical, allocatedBytes: c.allocated, reclaimableBytes: reclaimable,
                               sharesStorage: shares, sharesAllStorage: sharesAll,
                               created: c.created, modified: c.modified, isInGitRepo: git)
    }

    private func effectiveCreated(_ m: DuplicateMember) -> Date {
        m.created.timeIntervalSince1970 > 0 ? m.created : m.modified
    }

    private func precedes(_ a: DuplicateMember, _ b: DuplicateMember) -> Bool {
        switch options.keeperRule {
        case .oldest: break
        case .insideGitRepo:
            if a.isInGitRepo != b.isInGitRepo { return a.isInGitRepo }
        case .shortestPath:
            let ca = PathCanonicalizer.key(a.path).components.count, cb = PathCanonicalizer.key(b.path).components.count
            if ca != cb { return ca < cb }
        }
        let da = effectiveCreated(a), db = effectiveCreated(b)
        if da != db { return da < db }
        let la = a.path.utf8.count, lb = b.path.utf8.count
        if la != lb { return la < lb }
        return PathCanonicalizer.key(a.path).components.joined(separator: "/")
            < PathCanonicalizer.key(b.path).components.joined(separator: "/")
    }

    private func inGitRepo(_ path: String, scopeKey: [String], cache: inout [String: Bool]) -> Bool {
        var dir = (path as NSString).deletingLastPathComponent
        var visited: [String] = []
        var result = false
        while true {
            if let hit = cache[dir] { result = hit; break }
            visited.append(dir)
            var st = stat()
            if lstat(dir + "/.git", &st) == 0 { result = true; break }
            if PathCanonicalizer.key(dir).components.count <= scopeKey.count || dir == "/" { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        for d in visited { cache[d] = result }
        return result
    }
}
