import DiskKeeperCore
import SwiftUI

/// Will move · Frees after emptying Trash · Skipped.
struct CleanupSummaryTrio: View {
    let plan: CleanupPlan

    /// Apps and duplicate copies (clones, hard links) may free less than their size; Duplicates says "up to" too.
    private var freesIsUpperBound: Bool {
        plan.executableEntries.contains { e in
            if case .trashApplication = e.item.cleanupMethod { return true }
            return e.item.category == .duplicate || e.item.flags.contains(.sharedStorage)
        }
    }

    private var hasToolCommands: Bool { plan.hasExecutableToolCommands }

    var body: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            card(hasToolCommands ? CleanupCopy.trioWillClean : CleanupCopy.trioWillMove,
                 CleanupCopy.trioItems(plan.executableEntries.count), muted: false)
            card(hasToolCommands ? CleanupCopy.trioFreesUpTo : CleanupCopy.trioFrees,
                 SizeText.string(plan.reclaimableBytes, hasToolCommands || freesIsUpperBound ? .upTo : .exact), muted: false)
            card(CleanupCopy.trioSkipped, CleanupCopy.trioItems(plan.blockedCount), muted: plan.blockedCount == 0)
        }
    }

    private func card(_ title: String, _ value: String, muted: Bool) -> some View {
        SectionCard(padding: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.adkText3)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(muted ? .adkText3 : .adkText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CleanupCopy.itemAndReason(name: title, reason: value))
    }
}
