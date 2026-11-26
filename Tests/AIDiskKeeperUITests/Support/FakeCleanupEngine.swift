import DiskKeeperCore
import Foundation
@testable import AIDiskKeeperUI

/// Records every call; never touches the filesystem.
actor FakeCleanupEngine: CleanupEngineProtocol {
    /// item id → blockers to attach to that item's entry.
    var blockers: [String: [CleanupBlocker]] = [:]
    private(set) var issuedPlans: [CleanupPlan] = []
    private(set) var executedPlans: [CleanupPlan] = []
    private var errors: [CleanupError] = []
    var holdUntilCancelled = false
    var progressSteps: [CleanupProgress] = []

    func setBlockers(_ b: [String: [CleanupBlocker]]) { blockers = b }
    func throwOnce(_ e: CleanupError) { errors.append(e) }
    private var planHeld = false
    func holdPlan(_ v: Bool) { planHeld = v }
    func setHold(_ v: Bool) { holdUntilCancelled = v }
    func setProgress(_ p: [CleanupProgress]) { progressSteps = p }

    func plan(_ items: [ScanItem]) async -> CleanupPlan {
        while planHeld { try? await Task.sleep(nanoseconds: 5_000_000) }
        let entries = items.map {
            CleanupPlanEntry(item: $0, action: .trash, blockers: blockers[$0.id] ?? [], fingerprint: nil)
        }
        let p = CleanupPlan(createdAt: Date(), entries: entries)
        issuedPlans.append(p)
        return p
    }

    func execute(_ plan: CleanupPlan, progress: (@Sendable (CleanupProgress) -> Void)?) async throws -> CleanupReport {
        executedPlans.append(plan)
        if !errors.isEmpty { throw errors.removeFirst() }
        for p in progressSteps { progress?(p) }
        let startedAt = Date()
        var cancelled = false
        if holdUntilCancelled {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            cancelled = true
        }
        let results = plan.executableEntries.map {
            CleanupItemResult(itemID: $0.item.id, path: $0.item.path, bytes: $0.item.sizeAllocated, action: .trash,
                              outcome: cancelled ? .notAttempted : .trashed(trashPath: nil), finishedAt: Date())
        }
        return CleanupReport(planID: plan.id, startedAt: startedAt, finishedAt: Date(), results: results,
                             wasCancelled: cancelled, auditFailure: nil)
    }
}
