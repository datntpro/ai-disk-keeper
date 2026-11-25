import Darwin
import Foundation

/// Turns a dry-run plan into Trash moves and writes an audit log. See docs/cleanup.md.
public actor CleanupEngine {
    private let validator: ItemValidator
    private let auditLog: AuditLog
    private let trash: any TrashAdapter
    private let remover: any ItemRemover
    private let options: CleanupOptions
    private let now: @Sendable () -> Date
    private var issued: [UUID: Date] = [:]
    private var executed: Set<UUID> = []

    public init(pathGuard: ProtectedPaths,
                auditLog: AuditLog,
                trash: any TrashAdapter = FileManagerTrash(),
                remover: any ItemRemover = FileManagerRemover(),
                runningApps: any RunningAppChecking = UnknownRunningApps(),
                options: CleanupOptions = .init(),
                userID: uid_t = getuid(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.validator = ItemValidator(pathGuard: pathGuard, userID: userID, runningApps: runningApps,
                                       tolerance: options.tolerance)
        self.auditLog = auditLog
        self.trash = trash
        self.remover = remover
        self.options = options
        self.now = now
    }

    // MARK: Plan (dry run)

    /// Dry run. Never mutates anything. Records the plan id as issued.
    public func plan(_ items: [ScanItem]) async -> CleanupPlan {
        let action: CleanupAction = options.requestPermanentDelete ? .deletePermanently : .trash
        var blockers: [[CleanupBlocker]] = []
        var fingerprints: [ItemFingerprint?] = []
        var seenIDs: Set<String> = []
        var accepted: [(key: PathKey, id: String)] = []

        for item in items {
            if !seenIDs.insert(item.id).inserted {
                blockers.append([.duplicate])
                fingerprints.append(nil)
                continue
            }
            var b = validator.policyBlockers(item, action: action, options: options)
            let fast = validator.fastChecks(item, expected: nil)
            b += fast.blockers
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
        }

        // Slow re-size for the entries still unblocked, bounded sliding window.
        let pending = items.indices.filter { blockers[$0].isEmpty }
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

        let entries = items.indices.map {
            CleanupPlanEntry(item: items[$0], action: action, blockers: blockers[$0], fingerprint: fingerprints[$0])
        }
        let plan = CleanupPlan(createdAt: now(), entries: entries)
        issued[plan.id] = plan.createdAt
        return plan
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
        guard let createdAt = issued[plan.id] else {
            throw executed.contains(plan.id) ? CleanupError.planAlreadyExecuted : CleanupError.unknownPlan
        }
        if now().timeIntervalSince(createdAt) > options.planLifetime { throw CleanupError.planExpired }
        issued[plan.id] = nil
        executed.insert(plan.id)

        do { try await auditLog.open() } catch { throw CleanupError.auditLogUnavailable("\(error)") }

        let startedAt = now()
        var results: [CleanupItemResult] = []
        var wasCancelled = false
        var auditFailure: String?
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
            let (outcome, trashPath) = await run(entry)
            results.append(result(entry, outcome))
            do {
                try await auditLog.append(record(entry, outcome, runID: plan.id, trashPath: trashPath))
            } catch {
                auditFailure = "\(error)"
            }
            progress?(CleanupProgress(done: index + 1, total: total, currentPath: entry.item.path))
        }
        await auditLog.close()
        return CleanupReport(planID: plan.id, startedAt: startedAt, finishedAt: now(), results: results,
                             wasCancelled: wasCancelled, auditFailure: auditFailure)
    }

    private func run(_ entry: CleanupPlanEntry) async -> (CleanupOutcome, String?) {
        if !entry.blockers.isEmpty { return (.skipped(entry.blockers), nil) }
        let item = entry.item

        // Slow checks first, fast checks last: the window before the action is as short as possible.
        var blockers = validator.policyBlockers(item, action: entry.action, options: options)
        blockers += await validator.changeCheck(item)
        blockers += validator.fastChecks(item, expected: entry.fingerprint).blockers
        if !blockers.isEmpty { return (.skipped(blockers), nil) }

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

    private func result(_ entry: CleanupPlanEntry, _ outcome: CleanupOutcome) -> CleanupItemResult {
        CleanupItemResult(itemID: entry.item.id, path: entry.item.path, bytes: entry.item.sizeAllocated,
                          action: entry.action, outcome: outcome, finishedAt: now())
    }

    private func record(_ entry: CleanupPlanEntry, _ outcome: CleanupOutcome, runID: UUID,
                        trashPath: String?) -> AuditRecord {
        var kind = "failed"
        var reasons: [String] = []
        var error: String?
        var path = trashPath
        switch outcome {
        case .trashed: kind = "trashed"
        case .deleted: kind = "deleted"
        case .skipped(let b): kind = "skipped"; reasons = b.map(\.code)
        case .failed(let e): error = e
        case .notAttempted: break
        }
        if case .trashed(let p) = outcome { path = p }
        return AuditRecord(timestamp: now(), runID: runID, itemID: entry.item.id, path: entry.item.path,
                           bytes: entry.item.sizeAllocated, action: entry.action, result: kind,
                           trashPath: path, ruleID: entry.item.ruleID, tool: entry.item.tool,
                           reasons: reasons, error: error)
    }
}
