import SwiftUI

/// "Quit Claude" marker for items whose app must be closed before cleaning.
struct QuitAppBadge: View {
    let bundleID: String
    var body: some View {
        let name = AppNameResolver.name(forBundleID: bundleID)
        Label(L10n.tr("quit.badge", "Quit \(name)"), systemImage: "power")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.tr("quit.a11y", "Requires quitting \(name)"))
    }
}

/// Prominent note at the top of the detail pane.
struct QuitAppNote: View {
    let bundleID: String
    var body: some View {
        let name = AppNameResolver.name(forBundleID: bundleID)
        VStack(alignment: .leading, spacing: 4) {
            QuitAppBadge(bundleID: bundleID)
            Text(L10n.tr("quit.note", "\(name) is using this. Quit \(name) yourself, then click Re-check before cleaning. AI Disk Keeper never quits other apps for you."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
