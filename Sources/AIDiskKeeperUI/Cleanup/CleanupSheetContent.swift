import DiskKeeperCore
import SwiftUI

/// Renders the cleanup flow state: preview, progress, results or failure.
struct CleanupSheetContent: View {
    let flow: CleanupFlowModel
    let environment: PathEnvironment
    let onFinished: (Set<ScanItem.ID>) -> Void

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
        case .executing(let plan, let progress):
            CleanupProgressView(plan: plan, progress: progress, onStop: { flow.stop() })
        case .finished(let report, _):
            CleanupResultView(report: report, environment: environment) { ids in
                onFinished(ids)
                flow.dismiss()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                HStack { Spacer(); Button(CleanupCopy.done) { flow.dismiss() } }
            }
            .padding(24).frame(minWidth: 420)
        }
    }
}
