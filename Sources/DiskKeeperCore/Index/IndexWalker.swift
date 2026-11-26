import Darwin
import Foundation

/// fts(3) loop that builds a `DiskTree`. Byte semantics are identical to `FileTreeWalker`/`FileSizer`.
/// Runs on one GCD thread; nothing here is shared.
struct IndexWalker {
    let options: IndexOptions
    let rootPath: String              // lexical, no trailing slash (except "/")
    let scope: DiskIndexer.Scope
    let pathGuard: ProtectedPaths
    let rootStat: stat

    private static let dataless = UInt32(SF_DATALESS)
    private static let compressed = UInt32(UF_COMPRESSED)

    private struct Frame {
        var node: Int32
        var level: Int
        /// Descendants are not materialized (package or budget fold).
        var folding: Bool
        /// A real node owns this frame (false for budget-fold pseudo frames: contributions go to the ancestor).
        var materialized: Bool
        var guardState: IndexGuard.State
        var smallCount: UInt32 = 0
        var smallAllocated: Int64 = 0
        var smallLogical: Int64 = 0
        var smallNewest: Double = DiskTree.noMtime
        var needsCollapse = false
    }

    func run(shouldCancel: @Sendable () -> Bool, progress: (@Sendable (IndexProgress) -> Void)?) throws -> DiskTree {
        let clock = ContinuousClock()
        let started = clock.now
        var stats = IndexStats()
        let b = DiskTreeBuilder()

        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(rootPath, &resolved) != nil else {
            throw DiskIndexerError.rootInaccessible(rootPath, errno)
        }
        let physicalRoot = String(cString: resolved)

        let oldPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if oldPolicy != -1 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, oldPolicy)
            }
        }

        guard let cPath = strdup(rootPath) else { throw DiskIndexerError.walkFailed(rootPath, ENOMEM) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            throw DiskIndexerError.walkFailed(rootPath, errno)
        }
        defer { fts_close(fts) }

        let rootDev = rootStat.st_dev
        var seen = Set<InodeKey>()
        var stack: [Frame] = []
        var allocatedSoFar: Int64 = 0
        var lastProgress = started
        let maxIssues = options.maxRecordedIssues
        let fileNodeThreshold = options.fileNodeThreshold
        let recordThreshold = options.fileRecordThreshold
        let datalessOverride = options._datalessOverride

        @inline(__always) func mtime(_ ts: timespec) -> Double { Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 }
        @inline(__always) func blocks(_ st: UnsafeMutablePointer<stat>) -> Int64 { Int64(st.pointee.st_blocks) * 512 }

        func issue(_ ent: UnsafeMutablePointer<FTSENT>, _ kind: SizingIssue.Kind? = nil) {
            let code = ent.pointee.fts_errno
            stats.issueCount += 1
            if stats.issues.count < maxIssues {
                stats.issues.append(SizingIssue(path: String(cString: ent.pointee.fts_path),
                                                kind: kind ?? SizingIssue.kind(forErrno: code), errno: code))
            }
        }

        func closeTop() {
            let f = stack.removeLast()
            guard f.materialized else { return }
            if f.smallCount > 0 {
                if b.nodeCount < options.maxNodes {
                    b.addNode(parent: f.node, name: nil, flags: .smallItems, allocated: f.smallAllocated,
                              logical: f.smallLogical, fileCount: f.smallCount, mtime: f.smallNewest)
                } else {
                    b.addFlags(f.node, .collapsed)
                    stats.nodeBudgetHit = true
                }
            }
            if f.needsCollapse { b.addFlags(f.node, .collapsed) }
            if let parent = stack.last {
                let i = Int(f.node)
                b.addTotals(parent.node, allocated: b.allocated[i], logical: b.logical[i], files: b.fileCounts[i], mtime: b.mtimes[i])
            }
        }
        func close(downTo level: Int) {
            while let top = stack.last, top.level >= level { closeTop() }
        }

        let indexGuard = IndexGuard(pathGuard: pathGuard, rootPath: rootPath, physicalRoot: physicalRoot)
        func evaluate(_ ent: UnsafeMutablePointer<FTSENT>, parent: Frame?) -> (flags: NodeFlags, state: IndexGuard.State) {
            let path = String(cString: ent.pointee.fts_path)
            return indexGuard.classify(path: path, name: String(decoding: nameBuffer(ent), as: UTF8.self),
                                       level: Int(ent.pointee.fts_level), parent: parent?.guardState)
        }

        func nameBuffer(_ ent: UnsafeMutablePointer<FTSENT>) -> UnsafeRawBufferPointer {
            let offset = MemoryLayout<FTSENT>.offset(of: \.fts_name)!
            return UnsafeRawBufferPointer(start: UnsafeRawPointer(ent) + offset, count: Int(ent.pointee.fts_namelen))
        }

        func isDataless(_ st: UnsafeMutablePointer<stat>, _ ent: UnsafeMutablePointer<FTSENT>) -> Bool {
            if (st.pointee.st_flags & Self.dataless) != 0 { return true }
            if let o = datalessOverride { return o(String(cString: ent.pointee.fts_path)) }
            return false
        }

        errno = 0
        while let ent = fts_read(fts) {
            options._entryHook?()
            if shouldCancel() { throw CancellationError() }

            let info = Int32(ent.pointee.fts_info)
            let level = Int(ent.pointee.fts_level)
            if info == FTS_DP { close(downTo: level); continue }
            if info == FTS_DNR {
                // Already counted at its FTS_D visit; only record the issue and mark the node.
                issue(ent)
                if let top = stack.last, top.level == level, top.materialized {
                    b.addFlags(top.node, ent.pointee.fts_errno == EPERM ? .needsFullDiskAccess : .unreadable)
                }
                continue
            }
            close(downTo: level)
            stats.entriesVisited += 1
            let st = ent.pointee.fts_statp

            switch info {
            case FTS_D:
                guard let st else { break }
                let own = blocks(st)
                let t = mtime(st.pointee.st_mtimespec)
                if level == 0 {
                    stats.directoryCount += 1
                    allocatedSoFar += own
                    let ev = evaluate(ent, parent: nil)
                    let id = b.addNode(parent: -1, name: nil, flags: NodeFlags.directory.union(ev.flags), allocated: own, mtime: t)
                    stack.append(Frame(node: id, level: 0, folding: false, materialized: true, guardState: ev.state))
                    break
                }
                guard var top = stack.last else { break }
                if st.pointee.st_dev != rootDev {
                    _ = fts_set(fts, ent, Int32(FTS_SKIP))
                    stats.skippedMountPoints.append(String(cString: ent.pointee.fts_path))
                    if !top.folding, b.nodeCount < options.maxNodes {
                        b.addNode(parent: top.node, name: nameBuffer(ent), flags: [.directory, .otherVolume])
                    }
                } else if isDataless(st, ent) {
                    _ = fts_set(fts, ent, Int32(FTS_SKIP))
                    stats.datalessCount += 1
                    allocatedSoFar += own
                    b.addTotals(top.node, allocated: own, logical: 0, files: 0, mtime: t)
                    if !top.folding, b.nodeCount < options.maxNodes {
                        b.addNode(parent: top.node, name: nameBuffer(ent), flags: [.directory, .dataless], allocated: own, mtime: t)
                    }
                } else {
                    stats.directoryCount += 1
                    allocatedSoFar += own
                    if top.folding {
                        b.addTotals(top.node, allocated: own, logical: 0, files: 0, mtime: t)
                        break
                    }
                    if b.nodeCount >= options.maxNodes {
                        stats.nodeBudgetHit = true
                        b.addTotals(top.node, allocated: own, logical: 0, files: 0, mtime: t)
                        top.needsCollapse = true
                        stack[stack.count - 1] = top
                        stack.append(Frame(node: top.node, level: level, folding: true, materialized: false, guardState: top.guardState))
                        break
                    }
                    let name = nameBuffer(ent)
                    let isPackage = PackageDetector.isPackage(name: String(decoding: name, as: UTF8.self))
                    let ev = evaluate(ent, parent: top)
                    var flags = NodeFlags.directory.union(ev.flags)
                    if isPackage { flags.formUnion([.package, .collapsed]) }
                    let id = b.addNode(parent: top.node, name: name, flags: flags, allocated: own, mtime: t)
                    stack.append(Frame(node: id, level: level, folding: isPackage, materialized: true, guardState: ev.state))
                }
            case FTS_F, FTS_DEFAULT:
                guard let st, var top = stack.last else { break }
                let t = mtime(st.pointee.st_mtimespec)
                b.touch(top.node, t)
                let size = Int64(st.pointee.st_size)
                var repeatLink = false
                if st.pointee.st_nlink > 1 {
                    let key = InodeKey(device: st.pointee.st_dev, inode: st.pointee.st_ino)
                    if !seen.insert(key).inserted {
                        repeatLink = true
                        stats.hardlinkRepeatCount += 1
                    }
                }
                let isRegular = (st.pointee.st_mode & S_IFMT) == S_IFREG
                let alloc = repeatLink ? 0 : blocks(st)
                var fileFlags: NodeFlags = [.file]
                if repeatLink { fileFlags.insert(.hardlinkRepeat) }
                if !repeatLink {
                    stats.fileCount += 1
                    allocatedSoFar += alloc
                    if isDataless(st, ent) { fileFlags.insert(.dataless); stats.datalessCount += 1 }
                    if size >= 1 << 20 && alloc < size / 2 { fileFlags.insert(.sparse) }
                    if (st.pointee.st_flags & Self.compressed) != 0 { fileFlags.insert(.compressed) }
                    b.addTotals(top.node, allocated: alloc, logical: size, files: 1, mtime: t)
                }
                if top.folding { break }
                let big = size >= fileNodeThreshold
                if !big && !repeatLink {
                    top.smallCount &+= 1
                    top.smallAllocated += alloc
                    top.smallLogical += size
                    if t > top.smallNewest { top.smallNewest = t }
                    stack[stack.count - 1] = top
                    break
                }
                if !big { break }   // small hardlink repeat: nothing to show
                var nodeID = top.node
                var evFlags: NodeFlags = []
                if b.nodeCount < options.maxNodes {
                    let ev = evaluate(ent, parent: top)
                    evFlags = ev.flags
                    nodeID = b.addNode(parent: top.node, name: nameBuffer(ent), flags: fileFlags.union(ev.flags),
                                       allocated: alloc, logical: repeatLink ? 0 : size, fileCount: repeatLink ? 0 : 1, mtime: t)
                } else {
                    stats.nodeBudgetHit = true
                    top.needsCollapse = true
                    stack[stack.count - 1] = top
                    if top.guardState.protected { evFlags.insert(.protected) }
                    if top.guardState.system || top.guardState.outside { evFlags.insert(.outsideCleanableRoots) }
                }
                if isRegular && size >= recordThreshold {
                    if b.records.count < options.maxFileRecords {
                        b.records.append(FileRecord(
                            node: DiskNodeID(raw: nodeID), device: st.pointee.st_dev, inode: st.pointee.st_ino,
                            linkCount: st.pointee.st_nlink, logicalBytes: size, allocatedBytes: alloc,
                            modified: Date(timeIntervalSince1970: t),
                            created: Date(timeIntervalSince1970: mtime(st.pointee.st_birthtimespec)),
                            flags: fileFlags.subtracting(.file).union(evFlags)))
                    } else {
                        stats.fileRecordsTruncated = true
                    }
                }
            case FTS_SL, FTS_SLNONE:
                stats.symlinkCount += 1
                if let st, let top = stack.last { b.touch(top.node, mtime(st.pointee.st_mtimespec)) }
            case FTS_NS, FTS_ERR:
                issue(ent)
            case FTS_DC:
                issue(ent, .cycle)
            default:
                break
            }

            if let progress, stats.entriesVisited & 1023 == 0 {
                let now = clock.now
                if now - lastProgress >= options.progressInterval {
                    lastProgress = now
                    progress(IndexProgress(entriesVisited: stats.entriesVisited, directoriesVisited: stats.directoryCount,
                                           allocatedBytesSoFar: allocatedSoFar,
                                           currentDirectory: String(cString: ent.pointee.fts_path)))
                }
            }
        }
        if errno != 0 {
            stats.issueCount += 1
            if stats.issues.count < maxIssues {
                stats.issues.append(SizingIssue(path: rootPath, kind: .other, errno: errno))
            }
        }
        close(downTo: 0)
        stats.duration = clock.now - started
        let firmlinks: FirmlinkMap
        if case .fullDisk = scope { firmlinks = FirmlinkMap.load(path: options._firmlinksFile) } else { firmlinks = .empty }
        return b.freeze(rootPath: rootPath, physicalRootPath: physicalRoot, scope: scope, createdAt: Date(),
                        stats: stats, firmlinks: firmlinks)
    }
}
