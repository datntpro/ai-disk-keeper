import SwiftUI

struct EmptyStateView: View {
    var scan: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 48)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(loc("empty.title", "Find what AI tools are using on your disk")).font(.title2.weight(.semibold))
            Text(loc("empty.readOnlyNote", "Scanning is read-only. AI Disk Keeper only looks: nothing is changed until you review a cleanup plan and confirm it."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(action: scan) { Label(loc("action.scan", "Scan"), systemImage: "magnifyingglass") }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
