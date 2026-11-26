import Darwin
import Foundation

/// Turns a dry-run plan into Trash moves and writes an audit log. See docs/cleanup.md.
public actor CleanupEngine {
    private let validator: ItemValidator
    private let auditLog: AuditLog
    private let trash: any TrashAdapter
    private let remover: any ItemRemover
    private let toolCommands: ToolCommandPerformer?
    private let options: CleanupOptions
    private let now: @Sendable () -> Date
    private struct Issued {
        let plan: CleanupPlan
        let monotonic: ContinuousClock.Instant
    }
    private var issued: [UUID: Issued] = [:]
    private var executed: Set<UUID> = []
    /// `execute` is serialized: an actor is reentrant across `await`, and runs share one audit log.
    private var isExecuting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(pathGuard: ProtectedPaths,
                auditLog: AuditLog,
                trash: any TrashAdapter = FileManagerTrash(),
                remover: any ItemRemover = FileManagerRemover(),
                runningApps: any RunningAppChecking = UnknownRunningApps(),
                options: CleanupOptions = .init(),
                userID: uid_t = getuid(),
                appPolicy: ApplicationBundlePolicy? = nil,
                toolCommands: ToolCommandPerformer? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.validator = ItemValidator(pathGuard: pathGuard, userID: userID, runningApps: runningApps,
                                       tolerance: options.tolerance, appPolicy: appPolicy,
                                       toolCommandsAvailable: toolCommands != nil)
        self.toolCommands = toolCommands
        self.auditLog = auditLog
        self.trash = trash
        self.remover = remover
        self.options = options
        self.now = now
    }

    // MARK: Plan (dry run)

    /// Dry run. Never mutates anything. Records the plan id as issued. Duplicate items are blocked
    /// (`duplicateGroupUnknown`) because no groups were passed: use ``plan(_:duplicateGroups:)``.
    public func plan(_ items: [ScanItem]) async -> CleanupPlan {
        await plan(items, duplicateGroups: [:])
    }

    /// Dry run with the duplicate groups the items came from (keyed by `ScanItem.groupID`). Enforces the
    /// keep-one invariant: at least one unselected copy must still exist and hold the same content.
    public func plan(_ items: [ScanItem], duplicateGroups: [String: DuplicateGroup]) async -> CleanupPlan {
        let action: CleanupAction = options.requestPermanentDelete ? .deletePermanently : .trash
        var blockers: [[CleanupBlocker]] = []
        var fingerprints: [ItemFingerprint?] = []
        var appBundles: [AppBundleFingerprint?] = []
        var snapshots: [ToolCommandSnapshot?] = []
        var seenIDs: Set<String> = []
        var accepted: [(key: PathKey, id: String)] = []

        for item in items {
            if !seenIDs.insert(item.id).inserted {
                blockers.append([.duplicate])
                fingerprints.append(nil)
                appBundles.append(nil)
                snapshots.append(nil)
                continue
            }
            var b = validator.policyBlockers(item, action: action, options: options)
            let fast: (blockers: [CleanupBlocker], fingerprint: ItemFingerprint?)
            var bundle: AppBundleFingerprint?
            if case .trashApplication = item.cleanupMethod {
                let app = validator.appFastChecks(item, action: action, expected: nil)
                fast = (app.blockers, app.fingerprint)
                bundle = app.bundle
            } else if Self.isVirtualToolCommand(item) {
                fast = ([], nil)   // no file behind it: nothing to lstat
            } else {
                fast = validator.fastChecks(item, expected: nil)
            }
            b = (b + fast.blockers).uniqued()
            if b.isEmpty {
                let key = PathCanonicalizer.key(item.path)
                if let other = accepted.first(where: { Self.overlaps($0.key, key) }) {
                    b.append(.nestedInAnotherItem(otherItemID: other.id))
                } else {
                    accepted.append((key, item.id))
                }
            }
            blockers.append(b)
            fingerprints.append(fast.fingerprint)
            appBundles.append(bundle)
            snapshots.append(nil)
        }

        // Slow re-size for the entries still unblocked, bounded sliding window.
        let pending = items.indices.filter { blockers[$0].isEmpty && !Self.isVirtualToolCommand(items[$0]) }
        let window = max(1, options.maxConcurrentChecks)
        let validator = self.validator
        let checked: [(Int, [CleanupBlocker])] = await withTaskGroup(of: (Int, [CleanupBlocker]).self) { group in
            var next = 0
            var out: [(Int, [CleanupBlocker])] = []
            func launch() {
                guard next < pending.count else { return }
                let index = pending[next]
                let item = items[index]
                next += 1
                group.addTask { (index, await validator.changeCheck(item)) }
            }
            for _ in 0..<min(window, pending.count) { launch() }
            while let result = await group.next() {
                out.append(result)
                launch()
            }
            return out
        }
        for (index, extra) in checked { blockers[index] += extra }

        // Tool commands: the allowlist check always runs; probes (one cache per plan) only for unblocked entries.
        if let performer = toolCommands {
            let probes = ToolProbeCache()
            for index in items.indices {
                guard case .toolCommand = items[index].cleanupMethod, blockers[index] != [.duplicate] else { continue }
                if blockers[index].isEmpty {
                    let check = await performer.planCheck(items[index], probes: probes)
                    blockers[index] = check.blockers
                    snapshots[index] = check.snapshot
                } else {
                    blockers[index] = (blockers[index] + performer.allowlistBlockers(items[index])).uniqued()
                }
            }
        }

        var survivorSets: [Int: DuplicateSurvivorSet] = [:]
        await applyKeepOne(items: items, groups: duplicateGroups, blockers: &blockers, survivors: &survivorSets)

        let entries = items.indices.map {
            CleanupPlanEntry(item: items[$0], action: action, blockers: blockers[$0], fingerprint: fingerprints[$0],
                             survivors: survivorSets[$0], appBundle: appBundles[$0],
                             toolCommand: snapshots[$0])
        }
        let plan = CleanupPlan(createdAt: now(), entries: entries)
        issued[plan.id] = Issued(plan: plan, monotonic: ContinuousClock.now)
        return plan
    }

    private static func isVirtualToolCommand(_ item: ScanItem) -> Bool {
        if case .toolCommand = item.cleanupMethod { return item.isVirtual }
        return false
    }

    private static func overlaps(_ a: PathKey, _ b: PathKey) -> Bool {
        let n = min(a.components.count, b.components.count)
        return Array(a.components.prefix(n)) == Array(b.components.prefix(n))
    }

    // MARK: Execute

    /// Executes an issued, unexpired plan exactly once. Throws before touching anything if the plan is
    /// unknown/used/expired or the audit log can't be opened. Otherwise never throws.
    public func execute(_ plan: CleanupPlan,
                        progress: (@Sendable (CleanupProgress) -> Void)? = nil) async throws -> CleanupReport {
        guard let entry0 = issued[plan.id] else {
            throw executed.contains(plan.id) ? CleanupError.planAlreadyExecuted : CleanupError.unknownPlan
        }
        // Only exactly what `plan()` returned (and the user confirmed) may run.
        guard plan == entry0.plan else { throw CleanupError.planModified }
        // Expired by wall clock, by monotonic clock, or issued "in the future" (clock set back).
        let age = now().timeIntervalSince(entry0.plan.createdAt)
        let monotonicAge = entry0.monotonic.duration(to: ContinuousClock.now)
        let monotonicSeconds = Double(monotonicAge.components.seconds)
            + Double(monotonicAge.components.attoseconds) / 1e18
        if age < 0 || age > options.planLifetime || monotonicSeconds > options.planLifetime {
            throw CleanupError.planExpired
        }
        issued[plan.id] = nil
        executed.insert(plan.id)

        await acquireRunSlot()
        defer { releaseRunSlot() }

        do { try await auditLog.open() } catch { throw CleanupError.auditLogUnavailable("\(error)") }

        let startedAt = now()
        var results: [CleanupItemResult] = []
        var wasCancelled = false
        var auditFailure: String?
        var trashedKeys: Set<PathKey> = []
        let claimed = plan.entries.map { PathCanonicalizer.key($0.item.path) }
        let total = plan.entries.count

        for (index, entry) in plan.entries.enumerated() {
            if wasCancelled || auditFailure != nil {
                results.append(result(entry, .notAttempted))
                continue
            }
            if Task.isCancelled {
                wasCancelled = true
                results.append(result(entry, .notAttempted))
                continue
            }
            let (outcome, trashPath, toolRun) = await run(entry, trashedKeys: trashedKeys, claimed: claimed)
            switch outcome {
            case .trashed, .deleted: trashedKeys.insert(PathCanonicalizer.key(entry.item.path))
            default: break
            }
            results.append(result(entry, outcome))
            do {
                try await auditLog.append(record(entry, outcome, runID: plan.id, trashPath: trashPath, toolRun: toolRun))
            } catch {
                auditFailure = "\(error)"
            }
            progress?(CleanupProgress(done: index + 1, total: total, currentPath: entry.item.path))
        }
        await auditLog.close()
        return CleanupReport(planID: plan.id, startedAt: startedAt, finishedAt: now(), results: results,
                             wasCancelled: wasCancelled, auditFailure: auditFailure)
    }

    private func acquireRunSlot() async {
        if !isExecuting { isExecuting = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseRunSlot() {
        if waiters.isEmpty { isExecuting = false } else { waiters.removeFirst().resume() }
    }

    private func run(_ entry: CleanupPlanEntry, trashedKeys: Set<PathKey>,
                     claimed: [PathKey]) async -> (CleanupOutcome, String?, ToolRunRecord?) {
        if case .toolCommand = entry.item.cleanupMethod {
            let (outcome, record) = await runToolCommand(entry)
            return (outcome, nil, record)
        }
        let (outcome, trashPath) = await runTrash(entry, trashedKeys: trashedKeys, claimed: claimed)
        return (outcome, trashPath, nil)
    }

    /// Policy + (file targets) change and fast checks + the performer's fresh re-validation. Any blocker means the
    /// command is not run.
    private func runToolCommand(_ entry: CleanupPlanEntry) async -> (CleanupOutcome, ToolRunRecord?) {
        let item = entry.item
        let planned = ToolRunRecord(command: entry.toolCommand?.command, exitStatus: nil, durationMs: nil,
                                    stderrTail: nil, target: entry.toolCommand?.targetLabel)
        if !entry.blockers.isEmpty { return (.skipped(entry.blockers), planned) }
        var blockers = validator.policyBlockers(item, action: entry.action, options: options)
        if !item.isVirtual {
            blockers += await validator.changeCheck(item)
            blockers += validator.fastChecks(item, expected: entry.fingerprint).blockers
        }
        blockers = blockers.uniqued()
        if !blockers.isEmpty { return (.skipped(blockers), planned) }
        guard let toolCommands else { return (.skipped([.toolCommandUnavailable]), planned) }
        switch await toolCommands.execute(item, expected: entry.toolCommand) {
        case .blocked(let b, let record): return (.skipped(b), record)
        case .ran(let outcome, let record): return (outcome, record)
        }
    }

    private func runTrash(_ entry: CleanupPlanEntry, trashedKeys: Set<PathKey>, claimed: [PathKey]) async -> (CleanupOutcome, String?) {
        if !entry.blockers.isEmpty { return (.skipped(entry.blockers), nil) }
        let item = entry.item

        // Slow checks first, fast checks last: the window before the action is as short as possible.
        var blockers = validator.policyBlockers(item, action: entry.action, options: options)
        blockers += await validator.changeCheck(item)
        var bundleID: String?
        if case .trashApplication(let id) = item.cleanupMethod {
            // Apps are only ever moved to the Trash: there is no remover path, whatever the plan says.
            bundleID = id
            guard entry.action == .trash else { return (.skipped([.appBundleRefused(.permanentDelete)]), nil) }
            if entry.appBundle == nil { blockers.append(.identityChanged) }
            blockers += validator.appFastChecks(item, action: entry.action, expected: entry.appBundle,
                                                expectedGeneric: entry.fingerprint).blockers
        } else {
            blockers += validator.fastChecks(item, expected: entry.fingerprint).blockers
        }
        blockers = blockers.uniqued()
        if !blockers.isEmpty { return (.skipped(blockers), nil) }
        if let gate = await keepOneGate(entry, trashedKeys: trashedKeys, claimed: claimed) { return (.skipped([gate]), nil) }

        switch entry.action {
        case .trash:
            do {
                let resulting = try trash.trashItem(at: URL(fileURLWithPath: item.path))
                if let resulting, let expected = entry.fingerprint {
                    var st = stat()
                    if lstat(resulting.path, &st) != 0
                        || Int32(truncatingIfNeeded: st.st_dev) != expected.device || UInt64(st.st_ino) != expected.inode {
                        return (.failed("trashed item does not match the planned item (changed during cleanup)"),
                                resulting.path)
                    }
                }
                return (.trashed(trashPath: resulting?.path), resulting?.path)
            } catch {
                if let bundleID {
                    switch Self.posixCode(of: error) {
                    case EPERM: return (.skipped([.needsAppManagementPermission(bundleID: bundleID)]), nil)
                    case EACCES: return (.skipped([.requiresAdmin(bundleID: bundleID)]), nil)
                    default: break
                    }
                }
                return (.failed(error.localizedDescription), nil)
            }
        case .deletePermanently:
            do {
                try remover.removeItem(atPath: item.path)
                return (.deleted, nil)
            } catch {
                return (.failed(error.localizedDescription), nil)
            }
        }
    }

    /// The POSIX errno behind a Foundation error (`NSUnderlyingErrorKey` chain), if any.
    static func posixCode(of error: Error) -> Int32? {
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 5 {
            if e.domain == NSPOSIXErrorDomain { return Int32(truncatingIfNeeded: e.code) }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }

    private func result(_ entry: CleanupPlanEntry, _ outcome: CleanupOutcome) -> CleanupItemResult {
        CleanupItemResult(itemID: entry.item.id, path: entry.item.path, bytes: entry.item.sizeAllocated,
                          action: entry.action, outcome: outcome, finishedAt: now())
    }

    private func record(_ entry: CleanupPlanEntry, _ outcome: CleanupOutcome, runID: UUID,
                        trashPath: String?, toolRun: ToolRunRecord? = nil) -> AuditRecord {
        var kind = "failed"
        var reasons: [String] = []
        var error: String?
        var path = trashPath
        var bundleID: String?
        if case .trashApplication(let id) = entry.item.cleanupMethod { bundleID = id }
        switch outcome {
        case .trashed: kind = "trashed"
        case .deleted: kind = "deleted"
        case .ranCommand: kind = "ran"
        case .skipped(let b): kind = "skipped"; reasons = b.map(\.auditReason)
        case .failed(let e): error = e
        case .notAttempted: break
        }
        if case .trashed(let p) = outcome { path = p }
        return AuditRecord(timestamp: now(), runID: runID, itemID: entry.item.id, path: entry.item.path,
                           bytes: entry.item.sizeAllocated, action: entry.action, result: kind,
                           trashPath: path, ruleID: entry.item.ruleID, tool: entry.item.tool,
                           reasons: reasons, error: error, bundleID: bundleID,
                           command: toolRun?.command, exitStatus: toolRun?.exitStatus, durationMs: toolRun?.durationMs,
                           stderrTail: toolRun?.stderrTail, toolTarget: toolRun?.target)
    }
}
