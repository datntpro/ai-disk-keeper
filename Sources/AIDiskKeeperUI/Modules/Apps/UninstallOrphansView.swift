import DiskKeeperCore
import SwiftUI

/// Leftovers of apps that are gone. Nothing is ticked until you do it, and there is no select-all.
struct UninstallOrphansView: View {
    @Bindable var model: UninstallerModel
    let coordinator: CleanupCoordinator

    var body: some View {
        if model.orphans.isEmpty {
            StateView(kind: .empty, symbol: "checkmark.circle", title: UninstallerCopy.tabApps, message: UninstallerCopy.orphansNone)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: ADKTheme.Spacing.lg) {
                        Text(UninstallerCopy.orphansExplain).font(.callout).foregroundStyle(.adkText2)
                        ForEach(model.orphanGroups, id: \.key) { group in
                            VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                                Text(group.key).font(.headline).textSelection(.enabled)
                                SectionCard(padding: ADKTheme.Spacing.md) {
                                    VStack(spacing: 0) {
                                        ForEach(group.items, id: \.id) { item in
                                            row(item)
                                            if item.id != group.items.last?.id { Divider() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(ADKTheme.Spacing.lg)
                }
                SelectionActionBar(bytes: model.tickedOrphans.reduce(0) { $0 + $1.sizeAllocated },
                                   countLabel: UninstallerCopy.orphansSelected(Formatting.count(model.tickedOrphans.count)),
                                   primaryTitle: UninstallerCopy.orphansReview, count: model.tickedOrphans.count) {
                    model.reviewOrphans(using: coordinator)
                }
            }
        }
    }

    private func row(_ item: ScanItem) -> some View {
        let on = model.orphanSelection.contains(item.id)
        return HStack(spacing: ADKTheme.Spacing.md) {
            Toggle(isOn: Binding(get: { on }, set: { _ in model.toggleOrphan(item) })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(!item.isSelectable)
            VStack(alignment: .leading, spacing: 0) {
                PathText(UninstallLibrary.tilde(item.path, home: model.home))
                if let d = item.lastModified {
                    Text(UninstallerCopy.orphanModified(Formatting.absolute(d))).font(.caption).foregroundStyle(.adkText3)
                }
            }
            Spacer()
            SizeText(item.sizeAllocated).font(.callout).foregroundStyle(.adkText2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(UninstallerCopy.a11yRelated(item.path, "", SizeText.string(item.sizeAllocated, .exact),
                                                        on ? UninstallerCopy.ticked : UninstallerCopy.unticked))
    }
}
