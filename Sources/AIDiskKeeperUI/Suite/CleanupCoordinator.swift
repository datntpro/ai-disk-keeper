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
    @ObservationIgnored private var onRescan: (@MainActor () -> Void)?

    public init(holder: CleanupEngineHolder) { self.holder = holder }

    /// Opens the sheet on a dry-run plan for `items`. Duplicate items need their `duplicateGroups` (keyed by
    /// `ScanItem.groupID`) so the engine can enforce keep-one. No-op while the engine is unavailable, and while a flow is
    /// active: the running flow keeps its own `onFinished`/`onRescan` (a second `review` would swap them mid-flow).
    /// `onRescan` is the originating screen's own "check again" (Duplicates re-hashes); without it the Re-scan
    /// next step starts a normal scan.
    public func review(_ items: [ScanItem], duplicateGroups: [String: DuplicateGroup] = [:],
                       onRescan: (@MainActor () -> Void)? = nil,
                       onFinished: @escaping @MainActor (Set<ScanItem.ID>) -> Void) {
        guard let engine = holder.engine, flow?.isActive != true else { return }
        let flow = flow ?? CleanupFlowModel(engine: engine)
        self.flow = flow
        self.onFinished = onFinished
        self.onRescan = onRescan
        Task { await flow.review(items, duplicateGroups: duplicateGroups) }
    }

    /// The sheet's results screen calls this with the ids that were trashed.
    public func finished(_ trashed: Set<ScanItem.ID>) { finished(trashed, report: nil) }

    public func finished(_ trashed: Set<ScanItem.ID>, report: CleanupReport?) {
        if let report { lastReport = report }
        let callback = onFinished
        onFinished = nil
        onRescan = nil
        callback?(trashed)
    }

    /// "Re-scan" next step: the originating screen's own re-check if it gave one, else a normal scan.
    public func requestRescan() {
        if let onRescan { onRescan() } else { rescanRequests += 1 }
    }

    /// Every way out of the sheet (Done, Esc, a click outside) lands here. A finished run is reported first, so
    /// `lastReport` and the screen's `onFinished` never depend on which button closed the results.
    public func dismiss() {
        if case .finished(let report, _)? = flow?.state {
            finished(Self.trashedIDs(in: report), report: report)
        }
        flow?.dismiss()
        if flow?.isActive != true { onFinished = nil; onRescan = nil }
    }

    static func trashedIDs(in report: CleanupReport) -> Set<ScanItem.ID> {
        Set(report.results.compactMap {
            switch $0.outcome {
            case .trashed, .ranCommand: $0.itemID
            default: nil
            }
        })
    }
}
