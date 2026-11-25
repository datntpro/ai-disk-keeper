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
        func finish() -> SizeReport {
            if let n = newest { report.newestModification = Date(timeIntervalSince1970: n) }
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
            default:
                report.rootKind = .other
                report.allocatedBytes = Int64(rootStat.st_blocks) * 512
                report.logicalBytes = Int64(rootStat.st_size)
                report.fileCount = 1
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
        var seen = Set<InodeKey>()
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
            report.entriesVisited += 1
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
                    touch(st.pointee.st_mtimespec)
                } else {
                    report.directoryCount += 1
                    report.allocatedBytes += Int64(st.pointee.st_blocks) * 512
                    touch(st.pointee.st_mtimespec)
                }
            case FTS_F, FTS_DEFAULT:
                guard let st else { break }
                touch(st.pointee.st_mtimespec)
                if st.pointee.st_nlink > 1 {
                    let key = InodeKey(device: st.pointee.st_dev, inode: st.pointee.st_ino)
                    if !seen.insert(key).inserted {
                        report.hardlinkDuplicateCount += 1
                        break
                    }
                }
                report.fileCount += 1
                report.allocatedBytes += Int64(st.pointee.st_blocks) * 512
                report.logicalBytes += Int64(st.pointee.st_size)
            case FTS_SL, FTS_SLNONE:
                report.symlinkCount += 1
                if let st { touch(st.pointee.st_mtimespec) }
            case FTS_DNR:
                record(ent)
                if let st {
                    report.directoryCount += 1
                    report.allocatedBytes += Int64(st.pointee.st_blocks) * 512
                    touch(st.pointee.st_mtimespec)
                }
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
        return finish()
    }
}
