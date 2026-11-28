import Darwin
import Foundation
import os

struct InodeKey: Hashable {
    let device: Int32
    let inode: UInt64
}

final class CancellationFlag: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func set() { lock.withLock { $0 = true } }
    var isSet: Bool { lock.withLock { $0 } }
}

/// fts(3)-based walker. `FTS_NOCHDIR` is mandatory: without it fts changes the process-wide cwd.
struct FileTreeWalker {
    let options: FileSizer.Options
    let path: String
    let rootStat: stat

    private static let dataless = UInt32(SF_DATALESS)

    func run(
        shouldCancel: @Sendable () -> Bool,
        progress: (@Sendable (SizeProgress) -> Void)?
    ) throws -> SizeReport {
        var report = SizeReport()
        var newest: Double? = nil

        func touch(_ ts: timespec) {
            let v = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
            if newest == nil || v > newest! { newest = v }
        }
        // H6: private (really freed) bytes. Only metadata is read (`getattrlist`), never contents.
        let measure = options.measurePrivateBytes
        let probeMin = options.privateProbeMinFileSize
        let probe: @Sendable (String) -> CloneInfo = options._cloneProbe ?? { CloneProbe.probe($0) }
        var privateSum: Int64 = 0
        var estimate = false
        /// What deleting this regular file frees, assuming all its hard links are inside the tree.
        func privateBytes(path: UnsafePointer<CChar>?, allocated: Int64, size: Int64) -> Int64 {
            guard let path, size >= probeMin, allocated > 0 else { return allocated }
            switch probe(String(cString: path)) {
            case .known(_, _, let priv, _, _):
                report.probedBytes += allocated
                return min(max(0, priv), allocated)    // never more than the file occupies
            case .unknown:
                estimate = true                          // counted at its allocated size: an upper bound
                return allocated
            }
        }
        func finish() -> SizeReport {
            if let n = newest { report.newestModification = Date(timeIntervalSince1970: n) }
            if measure { report.privateBytes = max(0, privateSum); report.privateIsEstimate = estimate }
            return report
        }

        let mode = rootStat.st_mode & S_IFMT
        if mode != S_IFDIR {
            touch(rootStat.st_mtimespec)
            switch mode {
            case S_IFLNK:
                report.rootKind = .symlink
                report.symlinkCount = 1
            case S_IFREG:
                report.rootKind = .file
                report.allocatedBytes = Int64(rootStat.st_blocks) * 512
                report.logicalBytes = Int64(rootStat.st_size)
                report.fileCount = 1
                if measure {
                    // The other names of a multi-link root file are outside the item by definition.
                    if rootStat.st_nlink > 1 {
                        report.sharedOutsideBytes = report.allocatedBytes
                    } else {
                        privateSum = privateBytes(path: path, allocated: report.allocatedBytes,
                                                  size: Int64(rootStat.st_size))
                    }
                }
            default:
                report.rootKind = .other
                report.allocatedBytes = Int64(rootStat.st_blocks) * 512
                report.logicalBytes = Int64(rootStat.st_size)
                report.fileCount = 1
                privateSum = report.allocatedBytes
            }
            return finish()
        }

        // Do not trigger iCloud / File Provider downloads. Thread-scoped; GCD threads are reused → restore.
        let oldPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if oldPolicy != -1 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, oldPolicy)
            }
        }

        guard let cPath = strdup(path) else { throw FileSizerError.walkFailed(path: path, errno: ENOMEM) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            throw FileSizerError.walkFailed(path: path, errno: errno)
        }
        defer { fts_close(fts) }

        let rootDev = rootStat.st_dev
        // Only multi-link inodes: (links seen, st_nlink, allocated bytes).
        var seen: [InodeKey: (seen: Int, nlink: Int, bytes: Int64, priv: Int64)] = [:]
        let maxIssues = options.maxRecordedIssues
        let interval = max(1, options.progressInterval)

        func record(_ ent: UnsafeMutablePointer<FTSENT>, _ kind: SizingIssue.Kind? = nil) {
            let code = ent.pointee.fts_errno
            report.issueCount += 1
            if report.issues.count < maxIssues {
                report.issues.append(SizingIssue(
                    path: String(cString: ent.pointee.fts_path),
                    kind: kind ?? SizingIssue.kind(forErrno: code),
                    errno: code))
            }
        }

        errno = 0
        while let ent = fts_read(fts) {
            options._entryHook?()
            if shouldCancel() { throw CancellationError() }

            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP { continue }
            // FTS_DNR re-returns an entry already returned (and counted) as FTS_D.
            if info != FTS_DNR { report.entriesVisited += 1 }
            let st = ent.pointee.fts_statp

            switch info {
            case FTS_D:
                guard let st else { break }
                if ent.pointee.fts_level > 0 && st.pointee.st_dev != rootDev && !options.crossVolumes {
                    _ = fts_set(fts, ent, Int32(FTS_SKIP))
                    report.skippedMountPoints.append(String(cString: ent.pointee.fts_path))
                } else if ent.pointee.fts_level > 0 && (st.pointee.st_flags & Self.dataless) != 0 {
                    _ = fts_set(fts, ent, Int32(FTS_SKIP))
                    report.datalessSkippedCount += 1
                    report.allocatedBytes += Int64(st.pointee.st_blocks) * 512
                    privateSum += Int64(st.pointee.st_blocks) * 512
                    touch(st.pointee.st_mtimespec)
                } else {
                    report.directoryCount += 1
                    report.allocatedBytes += Int64(st.pointee.st_blocks) * 512
                    privateSum += Int64(st.pointee.st_blocks) * 512
                    touch(st.pointee.st_mtimespec)
                }
            case FTS_F, FTS_DEFAULT:
                guard let st else { break }
                touch(st.pointee.st_mtimespec)
                let allocated = Int64(st.pointee.st_blocks) * 512
                func priv() -> Int64 {   // probed at most once per inode, and only when measuring
                    measure && (st.pointee.st_mode & S_IFMT) == S_IFREG
                        ? privateBytes(path: ent.pointee.fts_path, allocated: allocated, size: Int64(st.pointee.st_size))
                        : allocated
                }
                if st.pointee.st_nlink > 1 {
                    let key = InodeKey(device: st.pointee.st_dev, inode: st.pointee.st_ino)
                    if var e = seen[key] {
                        e.seen += 1
                        seen[key] = e
                        report.hardlinkDuplicateCount += 1
                        break
                    }
                    seen[key] = (1, Int(st.pointee.st_nlink), allocated, priv())
                } else {
                    privateSum += priv()
                }
                report.fileCount += 1
                report.allocatedBytes += Int64(st.pointee.st_blocks) * 512
                report.logicalBytes += Int64(st.pointee.st_size)
            case FTS_SL, FTS_SLNONE:
                report.symlinkCount += 1
                if let st { touch(st.pointee.st_mtimespec) }
            case FTS_DNR:
                // Already counted (dirs, blocks, mtime) at its FTS_D visit; only record the issue.
                record(ent)
            case FTS_NS, FTS_ERR:
                record(ent)
            case FTS_DC:
                record(ent, .cycle)
            default:
                break
            }

            if let progress, report.entriesVisited % interval == 0 {
                progress(SizeProgress(entriesVisited: report.entriesVisited,
                                      allocatedBytesSoFar: report.allocatedBytes))
            }
        }
        if errno != 0 {
            let code = errno
            report.issueCount += 1
            if report.issues.count < maxIssues {
                report.issues.append(SizingIssue(path: path, kind: .other, errno: code))
            }
        }
        for e in seen.values {
            if e.seen < e.nlink {
                report.externallyLinkedFileCount += 1
                report.externallyLinkedBytes += e.bytes
                report.sharedOutsideBytes += e.bytes      // frees nothing: another name keeps the blocks
            } else {
                privateSum += e.priv
            }
        }
        return finish()
    }
}
