import DiskKeeperCore
import SwiftUI

struct SidebarView: View {
    let scan: ScanViewModel
    @Binding var selection: SidebarSelection

    var body: some View {
        let totals = scan.totals
        let tools = totals.byTool.sorted { $0.value.allocatedBytes != $1.value.allocatedBytes ? $0.value.allocatedBytes > $1.value.allocatedBytes : $0.key < $1.key }
        let cats = totals.byCategory.sorted { $0.value.allocatedBytes != $1.value.allocatedBytes ? $0.value.allocatedBytes > $1.value.allocatedBytes : $0.key.rawValue < $1.key.rawValue }
        List(selection: $selection) {
            Label(loc("sidebar.overview", "Overview"), systemImage: "square.grid.2x2").tag(SidebarSelection.overview)
            Section(loc("sidebar.byTool", "By tool")) {
                ForEach(tools, id: \.key) { tool, t in
                    row(tool.uiName, "wrench.and.screwdriver", t.allocatedBytes).tag(SidebarSelection.tool(tool))
                }
            }
            Section(loc("sidebar.byCategory", "By category")) {
                ForEach(cats, id: \.key) { cat, t in
                    row(cat.displayName, "folder", t.allocatedBytes).tag(SidebarSelection.category(cat))
                }
            }
            if !scan.warnings.isEmpty {
                Label(loc("sidebar.warnings", "Warnings (\(scan.warnings.count))"), systemImage: "exclamationmark.circle")
                    .tag(SidebarSelection.warnings)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ symbol: String, _ bytes: Int64) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(Formatting.bytes(bytes)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
