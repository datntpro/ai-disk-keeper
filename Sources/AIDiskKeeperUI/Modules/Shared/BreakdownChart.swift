import Charts
import DiskKeeperCore
import SwiftUI

/// A horizontal bar chart stacked by tier. Clicking a bar only filters the list; it never selects items.
struct BreakdownChart: View {
    let title: String
    let rows: [BreakdownRow]
    /// The active filter value (`BreakdownRow.id`), if any.
    let selected: String?
    let onSelect: (BreakdownRow) -> Void

    private let tiers: [RiskTier] = [.safe, .review, .keep]

    var body: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.adkText)
            Chart {
                ForEach(rows) { row in
                    ForEach(tiers, id: \.self) { tier in
                        BarMark(x: .value(Text(verbatim: "bytes"), row.bytes(for: tier)),
                                y: .value(Text(verbatim: "row"), row.chartID), width: .ratio(0.7))
                            .foregroundStyle(TierStyle.style(for: tier).color)
                            .opacity(selected == nil || selected == row.id ? 1 : 0.55)
                            .annotation(position: .trailing, alignment: .leading) {
                                if tier == .keep {
                                    Text(Formatting.bytes(row.total)).font(.caption).foregroundStyle(.adkText2)
                                }
                            }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYScale(domain: rows.map(\.chartID))
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let id = value.as(String.self), let row = rows.first(where: { $0.chartID == id }) {
                            Text(verbatim: row.label)
                        }
                    }
                }
            }
            .frame(height: CGFloat(max(rows.count, 1)) * 26 + 8)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { point in
                            guard let frame = proxy.plotFrame else { return }
                            let y = point.y - geo[frame].origin.y
                            if let id: String = proxy.value(atY: y, as: String.self),
                               let row = rows.first(where: { $0.chartID == id }), row.id != nil {
                                onSelect(row)
                            }
                        }
                }
            }
            // VoiceOver and keyboard users get one button per bar instead of the drawn marks.
            .accessibilityRepresentation {
                VStack {
                    ForEach(rows) { row in
                        if row.id != nil {
                            Button(row.accessibilityLabel) { onSelect(row) }
                                .accessibilityAddTraits(selected == row.id ? .isSelected : [])
                        } else {
                            Text(row.accessibilityLabel)
                        }
                    }
                }
            }
        }
    }
}

/// Collapsible "By tool" / "By project" charts above a module's item list.
struct BreakdownHeader: View {
    let ctx: ModuleContext
    let categories: Set<ItemCategory>
    let showTool: Bool
    let moduleKey: String
    private struct TaskKey: Hashable { let signature: [Int64]; let module: String }
    @AppStorage private var expanded: Bool
    @State private var toolRows: [BreakdownRow] = []
    @State private var projectRows: [BreakdownRow] = []

    init(ctx: ModuleContext, moduleKey: String, categories: Set<ItemCategory>, showTool: Bool) {
        self.ctx = ctx
        self.categories = categories
        self.showTool = showTool
        self.moduleKey = moduleKey
        _expanded = AppStorage(wrappedValue: true, "breakdown.expanded.\(moduleKey)")
    }

    private var scopedItems: [ScanItem] { ctx.scan.items.filter { categories.contains($0.category) } }
    private var signature: [Int64] { [Int64(ctx.scan.items.count), ctx.scan.items.reduce(0) { $0 &+ $1.sizeAllocated }] }

    var body: some View {
        let query = ctx.query.wrappedValue
        if !(toolRows.isEmpty && projectRows.isEmpty) || query.projectID != nil || query.toolFilter != nil {
            SectionCard(padding: ADKTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    HStack {
                        Button { expanded.toggle() } label: {
                            Label(expanded ? BreakdownCopy.hide : BreakdownCopy.show,
                                  systemImage: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                        }.buttonStyle(.plain)
                        Spacer()
                        if let label = activeFilterLabel(query) {
                            Text(BreakdownCopy.showing(label)).font(.caption).foregroundStyle(.adkText2)
                            Button(BreakdownCopy.clearFilter) {
                                ctx.query.wrappedValue.projectID = nil
                                ctx.query.wrappedValue.toolFilter = nil
                            }.controlSize(.small)
                        }
                    }
                    if expanded {
                        HStack(alignment: .top, spacing: ADKTheme.Spacing.xl) {
                            if showTool, !toolRows.isEmpty {
                                BreakdownChart(title: BreakdownCopy.byTool, rows: toolRows, selected: query.toolFilter?.rawValue) { row in
                                    guard let id = row.id else { return }
                                    ctx.query.wrappedValue.toolFilter = query.toolFilter?.rawValue == id ? nil : ToolID(rawValue: id)
                                }
                            }
                            if !projectRows.isEmpty {
                                BreakdownChart(title: BreakdownCopy.byProject, rows: projectRows, selected: query.projectID) { row in
                                    guard let id = row.id else { return }
                                    ctx.query.wrappedValue.projectID = query.projectID == id ? nil : id
                                }
                            }
                        }
                    }
                }
            }
            .padding([.horizontal, .top], ADKTheme.Spacing.lg)
            .task(id: TaskKey(signature: signature, module: moduleKey)) { await refresh() }
            .onDisappear { ctx.query.wrappedValue.projectID = nil; ctx.query.wrappedValue.toolFilter = nil }
        } else {
            Color.clear.frame(height: 0).task(id: TaskKey(signature: signature, module: moduleKey)) { await refresh() }
        }
    }

    private func activeFilterLabel(_ q: ItemQuery) -> String? {
        var parts: [String] = []
        if let t = q.toolFilter { parts.append(toolRows.first { $0.id == t.rawValue }?.label ?? t.uiName) }
        if let p = q.projectID {
            parts.append(projectRows.first { $0.id == p }?.label ?? (p == ItemQuery.noProject ? BreakdownCopy.noProject : p))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func refresh() async {
        let items = scopedItems
        let (tools, projects) = await Task.detached(priority: .userInitiated) {
            (ProjectBreakdown.byTool(items), ProjectBreakdown.byProject(items))
        }.value
        toolRows = tools
        projectRows = projects
    }
}
