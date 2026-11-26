import DiskKeeperCore
import SwiftUI

/// Table checkbox. Disabled for Keep and report-only items.
public struct SelectionCheckbox: View {
    let item: ScanItem
    let selection: SelectionModel

    public init(item: ScanItem, selection: SelectionModel) {
        self.item = item
        self.selection = selection
    }

    public var body: some View {
        if item.isSelectable {
            Toggle(CleanupCopy.selectItem(item.uiDisplayName()), isOn: Binding(
                get: { selection.isSelected(item) },
                set: { selection.setSelected(item, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(CleanupCopy.itemAndTier(name: item.uiDisplayName(), tier: TierStyle.style(for: item.tier).label))
                .accessibilityHint(Text(item.tier == .review ? CleanupCopy.reviewHint : ""))
        } else if item.tier == .keep {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                .help(CleanupCopy.keepHelp)
                .accessibilityLabel(CleanupCopy.itemAndReason(name: item.uiDisplayName(), reason: CleanupCopy.keepHelp))
        } else {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                .help(CleanupCopy.reportOnlyHelp)
                .accessibilityLabel(CleanupCopy.itemAndReason(name: item.uiDisplayName(), reason: CleanupCopy.reportOnlyHelp))
        }
    }
}
