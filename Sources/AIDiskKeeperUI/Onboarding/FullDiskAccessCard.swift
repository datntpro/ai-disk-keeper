import DiskKeeperCore
import SwiftUI
import AppKit

/// Status chip + explanation + deep link. Shared by onboarding and Settings.
struct FullDiskAccessCard: View {
    let status: FullDiskAccessStatus
    let recheck: () -> Void

    static let privacySettingsURL = SystemSettingsLinks.fullDiskAccess

    var statusText: String {
        switch status {
        case .granted: loc("fda.status.granted", "Granted ✓")
        case .notGranted: loc("fda.status.notGranted", "Not granted")
        case .unknown: loc("fda.status.unknown", "Unknown")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc("fda.title", "Full Disk Access (optional)")).font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(loc("fda.status.a11y", "Full Disk Access status: \(statusText)"))
            }
            Text(loc("fda.explain", "macOS hides a few locations, such as some app containers, unless you allow it. Without it, AI Disk Keeper still works and lists what it couldn't read."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(loc("fda.steps", "Turn on AI Disk Keeper in the list (use + if it's missing). You may need to quit and reopen the app, then press Re-check."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(loc("fda.openPrivacy", "Open Privacy Settings")) { NSWorkspace.shared.open(Self.privacySettingsURL) }
                Button(loc("fda.recheck", "Re-check"), action: recheck)
            }
        }
    }
}
