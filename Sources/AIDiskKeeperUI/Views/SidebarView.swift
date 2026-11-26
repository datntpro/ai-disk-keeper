import DiskKeeperCore
import SwiftUI

/// The suite sidebar: sections fed by `ModuleRegistry`, then the original By tool / By category browsing
/// inside AI Workspace. Computes badges from `scan.totals`; never iterates `scan.items`.
struct SidebarView: View {
    let ctx: ModuleContext
    @SceneStorage("sidebar.collapsedSections") private var collapsedRaw = ""
    @SceneStorage("sidebar.byTool.expanded") private var byToolExpanded = true
    @SceneStorage("sidebar.byCategory.expanded") private var byCategoryExpanded = true

    private var scan: ScanViewModel { ctx.scan }

    var body: some View {
        @Bindable var navigation = ctx.suite.navigation
        let sections = ModuleRegistry.sections(includeDisabled: ModuleRegistry.showsUnbuilt)
        List(selection: $navigation.selection) {
            ForEach(sections, id: \.0) { section, modules in
                if let title = section.title {
                    Section(title, isExpanded: expanded(section)) { rows(section, modules) }
                } else {
                    Section { rows(section, modules) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }

    @ViewBuilder private func rows(_ section: ModuleSection, _ modules: [ModuleDescriptor]) -> some View {
        ForEach(modules, id: \.id) { module in
            moduleRow(module).tag(SidebarSelection(module: module.id))
        }
        if section == .aiWorkspace { browseGroups }
        if section == .activity, !scan.warnings.isEmpty {
            Label(loc("sidebar.warnings", "Warnings (\(scan.warnings.count))"), systemImage: "exclamationmark.circle")
                .tag(SidebarSelection.warnings)
        }
    }

    @ViewBuilder private var browseGroups: some View {
        let totals = scan.totals
        let tools = totals.byTool.sorted { $0.value.allocatedBytes != $1.value.allocatedBytes ? $0.value.allocatedBytes > $1.value.allocatedBytes : $0.key < $1.key }
        let cats = totals.byCategory.sorted { $0.value.allocatedBytes != $1.value.allocatedBytes ? $0.value.allocatedBytes > $1.value.allocatedBytes : $0.key.rawValue < $1.key.rawValue }
        DisclosureGroup(loc("sidebar.byTool", "By tool"), isExpanded: $byToolExpanded) {
            ForEach(tools, id: \.key) { tool, t in
                row(tool.uiName, "wrench.and.screwdriver", t.allocatedBytes).tag(SidebarSelection.tool(tool))
            }
        }
        DisclosureGroup(loc("sidebar.byCategory", "By category"), isExpanded: $byCategoryExpanded) {
            ForEach(cats, id: \.key) { cat, t in
                row(cat.uiName, "folder", t.allocatedBytes).tag(SidebarSelection.category(cat))
            }
        }
    }

    private func moduleRow(_ module: ModuleDescriptor) -> some View {
        let badge = ModuleRegistry.provider(for: module.id).badge(ctx)
        return HStack {
            Label {
                Text(module.title)
            } icon: {
                Image(systemName: module.symbol).symbolRenderingMode(.hierarchical).foregroundStyle(.adkAccent)
            }
            Spacer()
            if let badge { Text(badge.text).monospacedDigit().font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(badge.map { loc("module.row.a11y", "\(module.title), \($0.a11yText)") } ?? module.title)
    }

    private func row(_ title: String, _ symbol: String, _ bytes: Int64) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(Formatting.bytes(bytes)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func expanded(_ section: ModuleSection) -> Binding<Bool> {
        let key = String(section.rawValue)
        return Binding(
            get: { !collapsedRaw.split(separator: ",").contains(Substring(key)) },
            set: { open in
                var set = Set(collapsedRaw.split(separator: ",").map(String.init))
                if open { set.remove(key) } else { set.insert(key) }
                collapsedRaw = set.sorted().joined(separator: ",")
            })
    }
}
