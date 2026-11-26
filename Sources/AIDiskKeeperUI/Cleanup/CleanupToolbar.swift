import DiskKeeperCore
import SwiftUI

/// "3 selected · 2.1 GB" and the primary "Review cleanup…" button.
struct CleanupToolbar: ToolbarContent {
    let scan: ScanViewModel
    let selection: SelectionModel
    let holder: CleanupEngineHolder
    let onReview: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let s = selection.summary(in: scan.items)
            if let err = holder.error {
                Label(CleanupCopy.unavailable(err), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .lineLimit(1).frame(maxWidth: 260)
            } else if s.count > 0 {
                Text(CleanupCopy.selectedSummary(count: s.count, bytes: s.bytes)).foregroundStyle(.secondary)
            }
            Button(action: onReview) {
                Label(CleanupCopy.reviewButton, systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(s.count == 0 || scan.isScanning || holder.engine == nil)
            .help(holder.error.map(CleanupCopy.unavailable) ?? CleanupCopy.reviewButton)
        }
    }
}
