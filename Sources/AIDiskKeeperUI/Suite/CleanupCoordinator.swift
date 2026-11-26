import DiskKeeperCore
import Foundation
import Observation

/// The one cleanup sheet for the whole window. Every module reviews items through here; nobody else touches
/// the cleanup engine. Screens own their selections: the coordinator never reads them.
@MainActor @Observable
public final class CleanupCoordinator {
    public private(set) var flow: CleanupFlowModel?
    /// The report of the most recent finished run (read-only; the Uninstaller reads it to follow up).
    public private(set) var lastReport: CleanupReport?
    /// Bumped by `requestRescan()`; the root view starts a normal scan when it changes.
    public private(set) var rescanRequests = 0
    public var isPresented: Bool { flow?.isActive ?? false }

    @ObservationIgnored private let holder: CleanupEngineHolder
    @ObservationIgnored private var onFinished: (@MainActor (Set<ScanItem.ID>) -> Void)?

    public init(holder: CleanupEngineHolder) { self.holder = holder }

    /// Opens the sheet on a dry-run plan for `items`. Duplicate items need their `duplicateGroups` (keyed by
    /// `ScanItem.groupID`) so the engine can enforce keep-one. No-op while the engine is unavailable.
    public func review(_ items: [ScanItem], duplicateGroups: [String: DuplicateGroup] = [:],
                       onFinished: @escaping @MainActor (Set<ScanItem.ID>) -> Void) {
        guard let engine = holder.engine else { return }
        let flow = flow ?? CleanupFlowModel(engine: engine)
        self.flow = flow
        self.onFinished = onFinished
        Task { await flow.review(items, duplicateGroups: duplicateGroups) }
    }

    /// The sheet's results screen calls this with the ids that were trashed.
    public func finished(_ trashed: Set<ScanItem.ID>) { finished(trashed, report: nil) }

    public func finished(_ trashed: Set<ScanItem.ID>, report: CleanupReport?) {
        if let report { lastReport = report }
        let callback = onFinished
        onFinished = nil
        callback?(trashed)
    }

    /// "Re-scan" next step: asks the window to start a normal scan.
    public func requestRescan() { rescanRequests += 1 }

    public func dismiss() {
        flow?.dismiss()
        if flow?.isActive != true { onFinished = nil }
    }
}
