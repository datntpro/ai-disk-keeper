import Darwin
import Foundation

/// All re-validation checks, kept separate from the engine so they are easy to test.
struct ItemValidator: Sendable {
    var pathGuard: ProtectedPaths
    let userID: uid_t
    let runningApps: any RunningAppChecking
    let tolerance: ChangeTolerance
    /// A plain `FileSizer`, never a `ScanContext`: the execute-time re-size must always walk the disk and must never
    /// see the incremental scan cache (T25). `ItemValidatorNoCacheTests` pins this.
    let sizer: FileSizer
    /// nil = every `.trashApplication` entry is blocked (fail closed).
    let appPolicy: ApplicationBundlePolicy?
    /// False = every `.toolCommand` entry is blocked (fail closed).
    let toolCommandsAvailable: Bool
    /// nil = in-use detection is not wired (tests only; `CleanupEngine.makeDefault` always wires it). When set, every
    /// file item is checked against a fresh process snapshot and a newest mtime under an hour old blocks.
    let inUse: (any ProcessUsageSource)?
    let now: @Sendable () -> Date

    init(pathGuard: ProtectedPaths, userID: uid_t, runningApps: any RunningAppChecking,
         tolerance: ChangeTolerance = .default, sizer: FileSizer = FileSizer(),
         appPolicy: ApplicationBundlePolicy? = nil, toolCommandsAvailable: Bool = false,
         inUse: (any ProcessUsageSource)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.inUse = inUse
        self.now = now
        self.toolCommandsAvailable = toolCommandsAvailable
        self.appPolicy = appPolicy
        self.pathGuard = pathGuard
        self.userID = userID
        self.runningApps = runningApps
        self.tolerance = tolerance
        self.sizer = sizer
    }

    /// Policy checks that need no filesystem access.
    func policyBlockers(_ item: ScanItem, action: CleanupAction, options: CleanupOptions,
                        userPolicy: UserPolicy = .empty, policyTrusted: Bool = true) -> [CleanupBlocker] {
        var out: [CleanupBlocker] = []
        if !policyTrusted { out.append(.userPolicyUnavailable) }
        // The user's current settings are re-read at execute time: an item hidden, a rule switched off or a stricter
        // override set after the plan was made still stops it. Overrides only ever add Keep, never lift anything.
        if userPolicy.hides(item) { out.append(.ignoredByUser) }
        if item.tier == .keep || userPolicy.effectiveTier(for: item) == .keep { out.append(.keepTier) }
        switch item.cleanupMethod {
        case .none: out.append(.notActionable)
        case .trashWorktree: out.append(.methodNotSupported("trashWorktree"))
        case .toolCommand: if !toolCommandsAvailable { out.append(.toolCommandUnavailable) }
        case .trashApplication:
            if action == .deletePermanently { out.append(.appBundleRefused(.permanentDelete)) }
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

    /// `.trashApplication`: the whole policy (checks 1-15) in place of the generic path/owner/parent checks.
    /// Never re-sizes the bundle; identity is the bundle + Info.plist fingerprint.
    func appFastChecks(_ item: ScanItem, action: CleanupAction, expected: AppBundleFingerprint?,
                       expectedGeneric: ItemFingerprint? = nil)
        -> (blockers: [CleanupBlocker], fingerprint: ItemFingerprint?, bundle: AppBundleFingerprint?) {
        guard let appPolicy else { return ([.appBundleRefused(.notApplicationMethod)], nil, nil) }
        var (blockers, bundle) = appPolicy.evaluate(item, action: action, expected: expected,
                                                    pathGuard: pathGuard, runningApps: runningApps)
        var fingerprint: ItemFingerprint?
        if let bundle {
            fingerprint = ItemFingerprint(device: bundle.bundleDevice, inode: bundle.bundleInode,
                                          kind: .directory, ownerUID: bundle.ownerUID)
            if let g = expectedGeneric, g.device != bundle.bundleDevice || g.inode != bundle.bundleInode,
               !blockers.contains(.identityChanged) {
                blockers.append(.identityChanged)
            }
        }
        return (blockers, fingerprint, bundle)
    }

    /// Slow check: re-size and compare with the scan.
    func changeCheck(_ item: ScanItem) async -> [CleanupBlocker] {
        // Apps: identity is checked by `appFastChecks`; re-sizing a 10 GB bundle at execute time is too slow.
        if case .trashApplication = item.cleanupMethod { return [] }
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
        var out: [CleanupBlocker] = []
        if inUse != nil, let current = report.newestModification,
           now().timeIntervalSince(current) < InUseAdjuster.recentWindow {
            out.append(.modifiedRecently)   // also a future mtime: unknown clock, treat as recent
        }
        guard let scannedModified = item.lastModified else { return out + [.changedSinceScan(detail)] }
        if let current = report.newestModification,
           current.timeIntervalSince(scannedModified) > tolerance.mtimeSlack {
            return out + [.changedSinceScan(detail)]
        }
        let slack = max(tolerance.sizeSlackBytes, Int64(tolerance.sizeSlackFraction * Double(item.sizeAllocated)))
        let delta = report.allocatedBytes - item.sizeAllocated
        if (delta < 0 ? -delta : delta) > slack { return out + [.changedSinceScan(detail)] }
        return out
    }

    // MARK: In use

    /// One reading of the process table. `index == nil` = unreadable (every file item is then blocked).
    struct InUseSnapshot: Sendable {
        let index: InUseIndex?
        let taken: ContinuousClock.Instant
    }

    /// A fresh snapshot, or nil when detection is not wired.
    func takeInUseSnapshot() -> InUseSnapshot? {
        guard let inUse else { return nil }
        let taken = ContinuousClock.now
        return InUseSnapshot(index: inUse.snapshot(userID: userID).map { InUseIndex($0, currentUID: userID) }, taken: taken)
    }

    /// Fails closed: an unreadable snapshot blocks. Apps (own running check) and virtual tool items (the tool refuses
    /// in-use objects itself) are not checked here.
    func inUseBlockers(_ item: ScanItem, snapshot: InUseSnapshot?) -> [CleanupBlocker] {
        guard inUse != nil else { return [] }
        if case .trashApplication = item.cleanupMethod { return [] }
        if item.isVirtual { return [] }
        guard let index = snapshot?.index else { return [.inUseUnknown] }
        if let holder = index.holder(of: item.path) { return [.inUse(process: holder.name, pid: holder.pid)] }
        return []
    }
}
