import DiskKeeperCore
import SwiftUI

/// Checkbox + path + match pill + size, for one leftover.
struct UninstallRelatedRow: View {
    let item: ScanItem
    let kind: UninstallRelatedKind?
    var owners: String = ""
    let home: String
    let isOn: Bool
    let toggle: () -> Void
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    private var pill: (text: String, ink: Color, fill: Color)? {
        switch kind {
        case .exact?: (UninstallerCopy.matchExact, .adkSafeInk, .adkSafeSoft)
        case .launchAgent?: (UninstallerCopy.matchLaunchAgent, .adkSafeInk, .adkSafeSoft)
        case .name?: (UninstallerCopy.matchName, .adkReviewInk, .adkReviewSoft)
        case .shared?: (UninstallerCopy.matchShared(owners), .adkReviewInk, .adkReviewSoft)
        case nil: nil
        }
    }

    var body: some View {
        let path = UninstallLibrary.tilde(item.path, home: home)
        HStack(spacing: ADKTheme.Spacing.md) {
            if kind != nil {
                Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden().disabled(!item.isSelectable)
            }
            PathText(path)
            Spacer(minLength: ADKTheme.Spacing.sm)
            if let pill {
                Text(pill.text).font(.caption.weight(.medium)).foregroundStyle(pill.ink)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(pill.fill, in: Capsule())
                    .overlay { if increasedContrast { Capsule().strokeBorder(.adkLineStrong, lineWidth: ADKTheme.hairline) } }
            }
            if item.flags.contains(.needsFullDiskAccess) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.adkText3).help(UninstallerCopy.sizeIncomplete)
            }
            SizeText(item.sizeAllocated).font(.callout).foregroundStyle(.adkText2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(UninstallerCopy.a11yRelated(
            path, pill?.text ?? "", SizeText.string(item.sizeAllocated, .exact),
            kind == nil ? "" : (isOn ? UninstallerCopy.ticked : UninstallerCopy.unticked)))
    }
}
