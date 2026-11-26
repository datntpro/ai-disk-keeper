import DiskKeeperCore
import SwiftUI

/// Renders the cleanup flow state: preview, progress, results or failure.
struct CleanupSheetContent: View {
    let flow: CleanupFlowModel
    let environment: PathEnvironment
    let coordinator: CleanupCoordinator
    /// Free bytes on the data volume. Read once when the preview appears; Core's existing API, read-only.
    var volumeFree: @Sendable () async -> Int64? = {
        try? await LiveVolumeInfoProvider().info(forPath: "/System/Volumes/Data").availableForImportantUsage
    }

    @State private var freeBefore: Int64?

    var body: some View {
        switch flow.state {
        case .idle, .planning:
            VStack(spacing: 16) {
                ProgressView()
                Button(CleanupCopy.cancel, role: .cancel) { flow.dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(40).frame(minWidth: 320)
        case .previewing(let plan, let notice):
            CleanupReviewSheet(plan: plan, notice: notice,
                               onRecheck: { Task { await flow.recheck() } },
                               onCancel: { flow.dismiss() },
                               onConfirm: { Task { await flow.confirm() } })
                .task { if freeBefore == nil { freeBefore = await volumeFree() } }
        case .executing(let plan, let progress):
            CleanupProgressView(plan: plan, progress: progress, onStop: { flow.stop() })
        case .finished(let report, let plan):
            CleanupResultView(report: report, environment: environment, plan: plan, freeBefore: freeBefore,
                              onRescan: { coordinator.requestRescan() }) { ids in
                coordinator.finished(ids, report: report)
                flow.dismiss()
            }
        case .failed(let message):
            StateView(kind: .blockingError, symbol: "exclamationmark.triangle", title: StateCopy.errorCleanupTitle, message: message,
                      actions: [StateAction(title: CleanupCopy.done) { flow.dismiss() }])
                .padding(24).frame(minWidth: 420)
        }
    }
}
