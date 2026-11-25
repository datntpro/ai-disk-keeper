import DiskKeeperCore
import SwiftUI
import AppKit

/// Status chip + explanation + deep link. Shared by onboarding and Settings.
struct FullDiskAccessCard: View {
    let status: FullDiskAccessStatus
    let recheck: () -> Void

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var statusText: String {
        switch status {
        case .granted: "Granted ✓"
        case .notGranted: "Not granted"
        case .unknown: "Unknown"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Full Disk Access (optional)").font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Full Disk Access status: \(statusText)")
            }
            Text("macOS hides a few locations, such as some app containers, unless you allow it. Without it, AI Disk Keeper still works and lists what it couldn't read.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Turn on AI Disk Keeper in the list (use + if it's missing). You may need to quit and reopen the app, then press Re-check.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacySettingsURL) }
                Button("Re-check", action: recheck)
            }
        }
    }
}
