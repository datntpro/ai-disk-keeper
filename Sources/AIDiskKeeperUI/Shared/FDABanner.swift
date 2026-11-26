import AppKit
import SwiftUI

/// "N folders need Full Disk Access": optional, never blocks. "Not now" hides it until the next launch only.
struct FDABanner: View {
    let count: Int
    @SceneStorage("fdaBanner.dismissed") private var dismissed = false
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: ADKTheme.Spacing.md) {
                Image(systemName: "lock.shield").foregroundStyle(.adkReviewInk).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.xs) {
                    Text(StateCopy.fdaTitle(count)).font(.callout.weight(.semibold))
                    Text(StateCopy.fdaBody).font(.caption).foregroundStyle(.adkText2)
                }
                Spacer(minLength: ADKTheme.Spacing.md)
                Button(StateCopy.fdaNotNow) { dismissed = true }.buttonStyle(.bordered)
                Button(StateCopy.fdaOpen) { NSWorkspace.shared.open(SystemSettingsLinks.fullDiskAccess) }
                    .buttonStyle(.borderedProminent).tint(.adkAccent)
            }
            .padding(ADKTheme.Spacing.md)
            .background(.adkReviewSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if increasedContrast { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.adkLineStrong) }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
