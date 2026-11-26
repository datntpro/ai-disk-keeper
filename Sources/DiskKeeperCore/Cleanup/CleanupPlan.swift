import Foundation

public struct CleanupPlanEntry: Identifiable, Codable, Sendable, Hashable {
    public var id: ScanItem.ID { item.id }
    public let item: ScanItem
    public let action: CleanupAction
    /// Empty ⇔ executable.
    public let blockers: [CleanupBlocker]
    /// nil when blocked before it could be taken.
    public let fingerprint: ItemFingerprint?
    /// Duplicate items only: the copies that stay behind, verified at plan time and again before the move.
    public let survivors: DuplicateSurvivorSet?
    /// `.trashApplication` only: bundle + Info.plist snapshot, compared again right before the move.
    public let appBundle: AppBundleFingerprint?
    public var isExecutable: Bool { blockers.isEmpty }

    public init(item: ScanItem, action: CleanupAction, blockers: [CleanupBlocker], fingerprint: ItemFingerprint?,
                survivors: DuplicateSurvivorSet? = nil, appBundle: AppBundleFingerprint? = nil) {
        self.appBundle = appBundle
        self.item = item
        self.action = action
        self.blockers = blockers
        self.fingerprint = fingerprint
        self.survivors = survivors
    }
}

/// A copy that is not selected and was verified to still hold the group's content.
public struct SurvivorFingerprint: Codable, Sendable, Hashable {
    public let path: String
    public let device: Int32
    public let inode: UInt64
    public let modified: Date

    public init(path: String, device: Int32, inode: UInt64, modified: Date) {
        self.path = path; self.device = device; self.inode = inode; self.modified = modified
    }
}

/// The keep-one evidence of one duplicate group (PLAN invariant 13). Part of the plan, so `planModified`
/// guards it too.
public struct DuplicateSurvivorSet: Codable, Sendable, Hashable {
    public let groupID: String
    public let logicalBytes: Int64
    public let partialDigest: String
    /// Unselected members verified at plan time.
    public let survivors: [SurvivorFingerprint]

    public init(groupID: String, logicalBytes: Int64, partialDigest: String, survivors: [SurvivorFingerprint]) {
        self.groupID = groupID; self.logicalBytes = logicalBytes
        self.partialDigest = partialDigest; self.survivors = survivors
    }
}

public struct CleanupPlan: Codable, Sendable, Hashable {
    public let id: UUID
    public let createdAt: Date
    /// Input order; duplicates kept as blocked entries.
    public let entries: [CleanupPlanEntry]

    public init(id: UUID = UUID(), createdAt: Date, entries: [CleanupPlanEntry]) {
        self.id = id
        self.createdAt = createdAt
        self.entries = entries
    }

    public var executableEntries: [CleanupPlanEntry] { entries.filter(\.isExecutable) }
    /// Σ `item.sizeAllocated` over executable entries.
    public var reclaimableBytes: Int64 { executableEntries.reduce(0) { $0 + $1.item.sizeAllocated } }
    public var blockedCount: Int { entries.count - executableEntries.count }
}

public struct CleanupOptions: Sendable, Hashable {
    /// The user asked for permanent delete in this run.
    public var requestPermanentDelete = false
    /// The Settings switch (the second confirmation lives in the UI).
    public var permanentDeleteEnabled = false
    public var planLifetime: TimeInterval = 15 * 60
    public var tolerance: ChangeTolerance = .default
    /// Plan-time re-sizing only.
    public var maxConcurrentChecks = 4

    public init(requestPermanentDelete: Bool = false,
                permanentDeleteEnabled: Bool = false,
                planLifetime: TimeInterval = 15 * 60,
                tolerance: ChangeTolerance = .default,
                maxConcurrentChecks: Int = 4) {
        self.requestPermanentDelete = requestPermanentDelete
        self.permanentDeleteEnabled = permanentDeleteEnabled
        self.planLifetime = planLifetime
        self.tolerance = tolerance
        self.maxConcurrentChecks = maxConcurrentChecks
    }
}

public enum CleanupOutcome: Codable, Sendable, Hashable {
    case trashed(trashPath: String?)
    case deleted
    case skipped([CleanupBlocker])
    case failed(String)
    /// Cancelled, or stopped after an audit failure.
    case notAttempted
}

public struct CleanupItemResult: Codable, Sendable, Hashable {
    public let itemID: String
    public let path: String
    public let bytes: Int64
    public let action: CleanupAction
    public let outcome: CleanupOutcome
    public let finishedAt: Date

    public init(itemID: String, path: String, bytes: Int64, action: CleanupAction,
                outcome: CleanupOutcome, finishedAt: Date) {
        self.itemID = itemID
        self.path = path
        self.bytes = bytes
        self.action = action
        self.outcome = outcome
        self.finishedAt = finishedAt
    }
}

public struct CleanupReport: Codable, Sendable, Hashable {
    public let planID: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let results: [CleanupItemResult]
    public let wasCancelled: Bool
    /// Set if the audit log stopped the run.
    public let auditFailure: String?

    public init(planID: UUID, startedAt: Date, finishedAt: Date, results: [CleanupItemResult],
                wasCancelled: Bool, auditFailure: String?) {
        self.planID = planID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.results = results
        self.wasCancelled = wasCancelled
        self.auditFailure = auditFailure
    }

    /// Σ bytes of trashed/deleted items. An upper bound: hardlinks and APFS clones may free less.
    public var freedBytes: Int64 {
        results.reduce(0) { sum, r in
            switch r.outcome {
            case .trashed, .deleted: sum + r.bytes
            default: sum
            }
        }
    }
}

public struct CleanupProgress: Sendable, Hashable {
    public let done: Int
    public let total: Int
    public let currentPath: String?

    public init(done: Int, total: Int, currentPath: String?) {
        self.done = done
        self.total = total
        self.currentPath = currentPath
    }
}

public enum CleanupError: Error, Equatable {
    case unknownPlan
    case planAlreadyExecuted
    case planExpired
    /// The plan passed to `execute` differs from the one `plan()` returned.
    case planModified
    case auditLogUnavailable(String)
}
