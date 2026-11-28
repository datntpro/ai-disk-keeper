import DiskKeeperCore
import SwiftUI

/// AI Workspace → Build caches: the regenerable caches of build tools, one item per cache (per project for
/// DerivedData, per image for Tart), never a wipe-all. Tools that can clean themselves get a copyable hint.
enum BuildCachesModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .buildCaches, section: .aiWorkspace, order: 4, symbol: "hammer",
                                             isEnabled: true, listCategories: [.systemJunk],
                                             listRulePrefixes: BuildCacheCatalog.rulePrefixes)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(BuildCachesDetail(ctx: ctx))
    }
}

private struct BuildCachesDetail: View {
    let ctx: ModuleContext

    var body: some View {
        let summary = BuildCachesSummary(items: ctx.scan.items)
        VStack(spacing: 0) {
            if !summary.groups.isEmpty { BuildCachesCard(summary: summary) }
            ScopedItemListView(ctx: ctx, scopeName: BuildCachesModule.descriptor.title)
        }
    }
}

/// What the card above the list shows: bytes per tool family and the hints for the caches that were found.
struct BuildCachesSummary: Equatable {
    struct Group: Equatable, Identifiable {
        let family: BuildCacheCatalog.Family
        let itemCount: Int
        let bytes: Int64
        var id: String { family.rawValue }
    }

    let groups: [Group]
    let hints: [BuildCacheCatalog.Hint]

    init(items: [ScanItem]) {
        let listed = items.filter { BuildCacheCatalog.lists(ruleID: $0.ruleID) || $0.ruleID == DerivedDataScanner.ruleID }
        var byFamily: [BuildCacheCatalog.Family: (Int, Int64)] = [:]
        for item in listed {
            let f = BuildCacheCatalog.family(ruleID: item.ruleID)
            let old = byFamily[f] ?? (0, 0)
            byFamily[f] = (old.0 + 1, old.1 + item.sizeAllocated)
        }
        groups = BuildCacheCatalog.Family.allCases.compactMap { f in
            byFamily[f].map { Group(family: f, itemCount: $0.0, bytes: $0.1) }
        }
        hints = BuildCacheCatalog.hints(forRuleIDs: Set(listed.map(\.ruleID)))
    }
}

private struct BuildCachesCard: View {
    let summary: BuildCachesSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach(summary.groups) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BuildCachesCopy.family(g.family)).font(.caption).foregroundStyle(.secondary)
                        Text(Formatting.bytes(g.bytes)).font(.callout.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
            if !summary.hints.isEmpty { CleanupHintCard(title: BuildCachesCopy.hintsTitle, hints: summary.hints.map { ($0.command, $0.copyable) }) }
            if summary.hints.contains(where: { $0.ruleIDs.contains("build-caches.tart-vms") }) {
                Text(BuildCachesCopy.reportOnly).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top], 12)
    }
}
