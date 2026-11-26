import DiskKeeperCore
import SwiftUI

public struct CleanupProgressView: View {
    let plan: CleanupPlan
    let progress: CleanupProgress?
    let onStop: () -> Void

    public init(plan: CleanupPlan, progress: CleanupProgress?, onStop: @escaping () -> Void) {
        self.plan = plan
        self.progress = progress
        self.onStop = onStop
    }

    public var body: some View {
        let total = progress?.total ?? plan.executableEntries.count
        let done = progress?.done ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text(CleanupCopy.progress(done: done, total: total)).font(.headline).monospacedDigit()
            if let path = progress?.currentPath {
                Text(path).font(.caption).foregroundStyle(.adkText3).lineLimit(1).truncationMode(.middle)
            }
            ProgressView(value: Double(done), total: Double(max(total, 1))).tint(.adkAccent)
            HStack {
                Spacer()
                Button(CleanupCopy.stop, role: .cancel, action: onStop)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
