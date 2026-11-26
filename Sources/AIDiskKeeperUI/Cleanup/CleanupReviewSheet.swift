import DiskKeeperCore
import SwiftUI

/// The dry run. The primary button is never the Return-key default, so a stray keypress can't confirm.
public struct CleanupReviewSheet: View {
    let plan: CleanupPlan
    let notice: CleanupFlowModel.Notice?
    let onRecheck: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    public init(plan: CleanupPlan, notice: CleanupFlowModel.Notice?, onRecheck: @escaping () -> Void,
                onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.plan = plan
        self.notice = notice
        self.onRecheck = onRecheck
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var executable: [CleanupPlanEntry] { plan.executableEntries }
    private var blocked: [CleanupPlanEntry] { plan.entries.filter { !$0.isExecutable } }

    /// bundle id → blocked entries, for entries whose only problem is a running app.
    private var quitGroups: [(bundleID: String, entries: [CleanupPlanEntry])] {
        var order: [String] = []
        var map: [String: [CleanupPlanEntry]] = [:]
        for e in blocked {
            for b in e.blockers {
                if case .appRunning(let id) = b {
                    if map[id] == nil { order.append(id) }
                    map[id, default: []].append(e)
                    break
                }
            }
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CleanupCopy.reviewTitle).font(.title2.bold())
            Text(CleanupCopy.reviewSubtitle).foregroundStyle(.secondary)
            if notice == .refreshedBecauseExpired {
                Label(CleanupCopy.expiredNotice, systemImage: "arrow.clockwise")
                    .padding(8).background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    quitSections
                    willMoveSection
                    wontCleanSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text(CleanupCopy.footerNote).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(CleanupCopy.cancel, role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(CleanupCopy.moveButton(plan.reclaimableBytes), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(executable.isEmpty)
                    .accessibilityLabel(CleanupCopy.moveButton(plan.reclaimableBytes))
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
    }

    @ViewBuilder private var quitSections: some View {
        ForEach(quitGroups, id: \.bundleID) { group in
            let bytes = group.entries.reduce(Int64(0)) { $0 + $1.item.sizeAllocated }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(CleanupCopy.quitHeading(app: AppNameResolver.name(forBundleID: group.bundleID),
                                                  count: group.entries.count, bytes: bytes),
                          systemImage: "exclamationmark.circle").font(.headline)
                    Spacer()
                    Button(CleanupCopy.recheck, action: onRecheck)
                }
                ForEach(group.entries) { row($0) }
            }
        }
    }

    @ViewBuilder private var willMoveSection: some View {
        if !executable.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(CleanupCopy.willMoveHeading(count: executable.count, bytes: plan.reclaimableBytes)).font(.headline)
                let reviewCount = executable.filter { $0.item.tier == .review }.count
                if reviewCount > 0 {
                    Text(CleanupCopy.reviewIncluded(reviewCount)).font(.callout).foregroundStyle(.orange)
                }
                let tools = Array(Set(executable.map(\.item.tool))).sorted { $0.uiName < $1.uiName }
                ForEach(tools, id: \.self) { tool in
                    Text(tool.uiName).font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(executable.filter { $0.item.tool == tool }) { row($0) }
                }
            }
        }
    }

    @ViewBuilder private var wontCleanSection: some View {
        let others = blocked.filter { e in
            !e.blockers.contains { if case .appRunning = $0 { return true } else { return false } }
        }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(CleanupCopy.wontCleanHeading(others.count)).font(.headline)
                ForEach(others) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.item.displayName)
                        ForEach(e.blockers, id: \.self) { b in
                            Text(CleanupCopy.sentence(for: b)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: CleanupPlanEntry) -> some View {
        let style = TierStyle.style(for: e.item.tier)
        return HStack {
            Label(style.label, systemImage: style.symbolName).foregroundStyle(style.color)
                .font(.caption).frame(width: 80, alignment: .leading)
            VStack(alignment: .leading) {
                Text(e.item.displayName)
                Text(e.item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(CleanupCopy.bytes(e.item.sizeAllocated)).monospacedDigit()
        }
    }
}
