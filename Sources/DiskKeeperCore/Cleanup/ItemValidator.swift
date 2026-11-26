import Darwin
import Foundation

/// All re-validation checks, kept separate from the engine so they are easy to test.
struct ItemValidator: Sendable {
    let pathGuard: ProtectedPaths
    let userID: uid_t
    let runningApps: any RunningAppChecking
    let tolerance: ChangeTolerance
    let sizer: FileSizer

    init(pathGuard: ProtectedPaths, userID: uid_t, runningApps: any RunningAppChecking,
         tolerance: ChangeTolerance = .default, sizer: FileSizer = FileSizer()) {
        self.pathGuard = pathGuard
        self.userID = userID
        self.runningApps = runningApps
        self.tolerance = tolerance
        self.sizer = sizer
    }

    /// Policy checks that need no filesystem access.
    func policyBlockers(_ item: ScanItem, action: CleanupAction, options: CleanupOptions) -> [CleanupBlocker] {
        var out: [CleanupBlocker] = []
        if item.tier == .keep { out.append(.keepTier) }
        switch item.cleanupMethod {
        case .none: out.append(.notActionable)
        case .trashWorktree: out.append(.methodNotSupported("trashWorktree"))
        case .toolCommand: out.append(.methodNotSupported("toolCommand"))
        case .trashApplication: out.append(.methodNotSupported("trashApplication"))
        case .trash: break
        }
        if action == .deletePermanently && !options.permanentDeleteEnabled {
            out.append(.permanentDeleteDisabled)
        }
        return out
    }

    /// Fast filesystem checks. Collects every blocker that applies but stops at the first FS failure.
    func fastChecks(_ item: ScanItem, expected: ItemFingerprint?)
        -> (blockers: [CleanupBlocker], fingerprint: ItemFingerprint?) {
        var out: [CleanupBlocker] = []
        if let denial = pathGuard.check(item.path).denial {
            out.append(.protectedPath(denial.reason, message: denial.message, pattern: denial.matchedPattern, whyID: denial.whyID))
        }

        var st = stat()
        if lstat(item.path, &st) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { out.append(.missing) }
            else { out.append(.sizingFailed("lstat failed (errno \(code))")) }
            return (out, nil)
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            out.append(.isSymlink)
            return (out, nil)
        }
        let kind: ItemFingerprint.Kind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        default: kind = .other
        }
        let fingerprint = ItemFingerprint(device: Int32(truncatingIfNeeded: st.st_dev), inode: UInt64(st.st_ino),
                                          kind: kind, ownerUID: UInt32(st.st_uid))

        if st.st_uid != userID { out.append(.notOwnedByUser(uid: UInt32(st.st_uid))) }

        if let expected, expected.device != fingerprint.device || expected.inode != fingerprint.inode
            || expected.kind != fingerprint.kind {
            out.append(.identityChanged)
        }

        // Parent chain: the lexical parent must not hide a symlink.
        let parent = (item.path as NSString).deletingLastPathComponent
        if let resolved = realpath(parent, nil) {
            defer { free(resolved) }
            let resolvedPath = String(cString: resolved)
            if PathCanonicalizer.key(resolvedPath) != PathCanonicalizer.key(parent) {
                out.append(.symlinkInParentChain(resolvedParent: resolvedPath))
            }
        } else {
            out.append(.symlinkInParentChain(resolvedParent: "(unresolvable)"))
        }

        if let bundle = item.requiresAppQuit {
            switch runningApps.isRunning(bundleID: bundle) {
            case .some(true): out.append(.appRunning(bundleID: bundle))
            case .none: out.append(.appStateUnknown(bundleID: bundle))
            case .some(false): break
            }
        }
        return (out, fingerprint)
    }

    /// Slow check: re-size and compare with the scan.
    func changeCheck(_ item: ScanItem) async -> [CleanupBlocker] {
        let report: SizeReport
        do {
            report = try await sizer.size(of: item.url)
        } catch FileSizerError.rootNotFound {
            return [.missing]
        } catch {
            return [.sizingFailed("\(error)")]
        }
        let detail = ChangeDetail(scannedBytes: item.sizeAllocated, currentBytes: report.allocatedBytes,
                                  scannedModified: item.lastModified, currentModified: report.newestModification)
        guard let scannedModified = item.lastModified else { return [.changedSinceScan(detail)] }
        if let current = report.newestModification,
           current.timeIntervalSince(scannedModified) > tolerance.mtimeSlack {
            return [.changedSinceScan(detail)]
        }
        let slack = max(tolerance.sizeSlackBytes, Int64(tolerance.sizeSlackFraction * Double(item.sizeAllocated)))
        let delta = report.allocatedBytes - item.sizeAllocated
        if (delta < 0 ? -delta : delta) > slack { return [.changedSinceScan(detail)] }
        return []
    }
}
