import DiskKeeperCore
import SwiftUI

/// The dry run. The primary button answers ⌘⏎ only and focus starts on Cancel, so a stray Return can't confirm.
public struct CleanupReviewSheet: View {
    let plan: CleanupPlan
    let notice: CleanupFlowModel.Notice?
    let onRecheck: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Namespace private var focusNamespace
    /// False for static renders (snapshots): `ImageRenderer` draws nothing inside a `ScrollView`.
    var scrolls = true

    public init(plan: CleanupPlan, notice: CleanupFlowModel.Notice?, onRecheck: @escaping () -> Void,
                onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.plan = plan
        self.notice = notice
        self.onRecheck = onRecheck
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var executable: [CleanupPlanEntry] { plan.executableEntries }

    private func runningAppID(_ e: CleanupPlanEntry) -> String? {
        for b in e.blockers { if case .appRunning(let id) = b { return id } }
        return nil
    }

    /// App-running entries first, then the others.
    private var blocked: [CleanupPlanEntry] {
        let all = plan.entries.filter { !$0.isExecutable }
        return all.filter { runningAppID($0) != nil } + all.filter { runningAppID($0) == nil }
    }

    /// The first blocked row of each running app carries the inline Re-check.
    private var recheckRowIDs: Set<ScanItem.ID> {
        var seen = Set<String>()
        var out = Set<ScanItem.ID>()
        for e in blocked { if let id = runningAppID(e), seen.insert(id).inserted { out.insert(e.id) } }
        return out
    }

    private var contextLine: String {
        let tools = Set(executable.map(\.item.tool))
        if tools.count == 1, let t = tools.first { return t.uiName }
        return CleanupCopy.several
    }

    private var tools: [ToolID] { Array(Set(executable.map(\.item.tool))).sorted { $0.uiName < $1.uiName } }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(contextLine.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.adkText3)
                Text(CleanupCopy.titleBytes(plan.reclaimableBytes)).font(.title2.bold())
                Text(CleanupCopy.dryRun).foregroundStyle(.adkText2)
            }
            if notice == .refreshedBecauseExpired {
                Label(CleanupCopy.expiredNotice, systemImage: "arrow.clockwise")
                    .padding(8).background(.adkReviewSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            CleanupSummaryTrio(plan: plan)
            planList
            Divider()
            Text(CleanupCopy.footerNote).font(.caption).foregroundStyle(.adkText3)
            HStack {
                Button(CleanupCopy.cancel, role: .cancel, action: onCancel)
                    .keyboardShortcut(CleanupSheetKeys.cancel)
                    .prefersDefaultFocus(CleanupSheetKeys.defaultFocus == .cancel, in: focusNamespace)
                Button(CleanupCopy.recheck, action: onRecheck)
                Spacer()
                validity
                Button(CleanupCopy.confirm(plan.reclaimableBytes), action: onConfirm)
                    .keyboardShortcut(CleanupSheetKeys.confirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.adkAccent)
                    .disabled(executable.isEmpty)
            }
            .focusScope(focusNamespace)
        }
        .padding(ADKTheme.Spacing.xl)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 460)
        .modifier(FormSizing())
    }

    @ViewBuilder private var planList: some View {
        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(tools, id: \.self) { tool in
                Text(tool.uiName).font(.subheadline.weight(.semibold)).foregroundStyle(.adkText2)
                    .padding(.top, 8).padding(.bottom, 2)
                ForEach(executable.filter { $0.item.tool == tool }) { CleanupPlanRow(entry: $0) }
            }
            if !blocked.isEmpty {
                Divider().padding(.vertical, 8)
                ForEach(blocked) { e in
                    CleanupPlanRow(entry: e, onRecheck: recheckRowIDs.contains(e.id) ? onRecheck : nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if scrolls { ScrollView { list } } else { list; Spacer(minLength: 0) }
    }

    private var validity: some View {
        let parts = CleanupCopy.planValidParts
        let end = plan.createdAt.addingTimeInterval(15 * 60)
        let range = plan.createdAt...max(end, plan.createdAt)
        return HStack(spacing: 0) {
            Text(verbatim: parts.before)
            Text(timerInterval: range, countsDown: true).monospacedDigit()
            Text(verbatim: parts.after)
        }
        .font(.caption).foregroundStyle(.adkText3)
    }
}

private struct FormSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.presentationSizing(.form) } else { content }
    }
}
