import AppKit
import DiskKeeperCore
import SwiftUI

public struct CleanupResultView: View {
    let report: CleanupReport
    let environment: PathEnvironment
    let plan: CleanupPlan?
    let freeBefore: Int64?
    let onRescan: (() -> Void)?
    let onDone: (Set<ScanItem.ID>) -> Void
    /// False for static renders (snapshots): `ImageRenderer` draws nothing inside a `ScrollView`.
    var scrolls = true

    public init(report: CleanupReport, environment: PathEnvironment, plan: CleanupPlan? = nil, freeBefore: Int64? = nil,
                onRescan: (() -> Void)? = nil, onDone: @escaping (Set<ScanItem.ID>) -> Void) {
        self.report = report
        self.environment = environment
        self.plan = plan
        self.freeBefore = freeBefore
        self.onRescan = onRescan
        self.onDone = onDone
    }

    private var trashedIDs: Set<ScanItem.ID> {
        Set(report.results.compactMap { if case .trashed = $0.outcome { $0.itemID } else { nil } })
    }
    private var failedCount: Int { report.results.filter { if case .failed = $0.outcome { true } else { false } }.count }
    private var skippedCount: Int { report.results.filter { if case .skipped = $0.outcome { true } else { false } }.count }

    private var title: String {
        if report.wasCancelled { return CleanupCopy.resultStopped }
        if failedCount > 0 || report.auditFailure != nil { return CleanupCopy.resultProblems }
        return CleanupCopy.resultComplete
    }
    private var summary: String {
        CleanupCopy.resultSummary(items: trashedIDs.count, errors: failedCount, skipped: skippedCount)
    }
    private var announcement: String { "\(title). \(Formatting.bytes(report.freedBytes)) \(summary)" }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button(CleanupCopy.openTrash) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: environment.home + "/.Trash"))
                }
                Button(CleanupCopy.showAuditLog) {
                    NSWorkspace.shared.activateFileViewerSelecting([AuditLog.defaultURL(environment: environment)])
                }
            }
            if report.auditFailure != nil { auditBanner }
            VStack(alignment: .leading, spacing: 2) {
                HeroNumberText(Formatting.bytes(report.freedBytes))
                Text(summary).foregroundStyle(.adkText2)
            }
            if let freeBefore {
                CleanupResultStrata(freeBefore: freeBefore, freed: report.freedBytes, animatesIn: scrolls)
            }
            Divider()
            rows
            HStack {
                Spacer()
                Button(CleanupCopy.done) { onDone(trashedIDs) }
                    .buttonStyle(.borderedProminent).tint(.adkAccent)
            }
        }
        .padding(ADKTheme.Spacing.xl)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { AccessibilityNotification.Announcement(announcement).post() }
    }

    @ViewBuilder private var rows: some View {
        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(report.results.enumerated()), id: \.offset) { _, r in resultRow(r) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if scrolls { ScrollView { list } } else { list; Spacer(minLength: 0) }
    }

    private var auditBanner: some View {
        HStack {
            Label(CleanupCopy.auditPaused, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.adkReviewInk)
            Spacer()
            Button(CleanupCopy.auditRevealFolder) {
                NSWorkspace.shared.activateFileViewerSelecting([AuditLog.defaultURL(environment: environment).deletingLastPathComponent()])
            }
        }
        .padding(8).background(.adkReviewSoft, in: RoundedRectangle(cornerRadius: 6))
    }

    private func outcomeText(_ r: CleanupItemResult) -> String {
        switch r.outcome {
        case .trashed:
            if let e = plan?.entries.first(where: { $0.id == r.itemID }), case .trashWorktree = e.item.cleanupMethod {
                return CleanupCopy.outcomePruned
            }
            return CleanupCopy.outcomeTrashed
        case .deleted: return CleanupCopy.outcomeTrashed
        case .skipped(let b): return CleanupCopy.outcomeSkipped(b.map { CleanupCopy.sentence(for: $0) }.joined(separator: " "))
        case .failed(let e): return CleanupCopy.outcomeFailed(e)
        case .notAttempted:
            return report.auditFailure != nil ? CleanupCopy.stoppedByAudit : CleanupCopy.stoppedByUser
        }
    }

    private func resultRow(_ r: CleanupItemResult) -> some View {
        let step = CleanupNextStep.step(for: r.outcome)
        let bad: Bool = { if case .trashed = r.outcome { false } else { true } }()
        return HStack(alignment: .top, spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: r.path).lastPathComponent).lineLimit(1)
                PathText(CleanupPlanRow.displayPath(r.path, home: environment.home))
                Text(outcomeText(r)).font(.caption).foregroundStyle(bad ? .adkReviewInk : .adkText3)
                if let step { nextStep(step, path: r.path) }
            }
            Spacer(minLength: 8)
            SizeText(r.bytes).foregroundStyle(bad ? .adkText3 : .adkText)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func nextStep(_ step: CleanupNextStep, path: String) -> some View {
        if let text = step.text {
            Text(text).font(.caption).foregroundStyle(.adkText2)
        } else if let title = step.buttonTitle {
            Button(title) { perform(step, path: path) }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.adkAccent)
        }
    }

    private func perform(_ step: CleanupNextStep, path: String) {
        switch step {
        case .rescan:
            onRescan?()
            onDone(trashedIDs)
        case .openAppManagement:
            NSWorkspace.shared.open(SystemSettingsLinks.appManagement)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        default: break
        }
    }
}
