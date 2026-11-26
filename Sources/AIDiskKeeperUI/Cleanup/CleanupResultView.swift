import AppKit
import DiskKeeperCore
import SwiftUI

public struct CleanupResultView: View {
    let report: CleanupReport
    let environment: PathEnvironment
    let onDone: (Set<ScanItem.ID>) -> Void

    public init(report: CleanupReport, environment: PathEnvironment, onDone: @escaping (Set<ScanItem.ID>) -> Void) {
        self.report = report
        self.environment = environment
        self.onDone = onDone
    }

    private var trashedIDs: Set<ScanItem.ID> {
        Set(report.results.compactMap { if case .trashed = $0.outcome { $0.itemID } else { nil } })
    }
    private var summaryLine: String {
        CleanupCopy.moved(count: trashedIDs.count, bytes: report.freedBytes)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summaryLine).font(.title3.bold())
            if report.auditFailure != nil {
                Label(CleanupCopy.auditWarning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(CleanupCopy.skippedHeading, report.results.compactMap { r in
                        if case .skipped(let b) = r.outcome { (r.path, b.map { CleanupCopy.sentence(for: $0) }.joined(separator: " ")) } else { nil }
                    })
                    section(CleanupCopy.failedHeading, report.results.compactMap { r in
                        if case .failed(let e) = r.outcome { (r.path, e) } else { nil }
                    })
                    section(CleanupCopy.notAttemptedHeading, report.results.compactMap { r in
                        if case .notAttempted = r.outcome {
                            (r.path, report.auditFailure != nil ? CleanupCopy.stoppedByAudit : CleanupCopy.stoppedByUser)
                        } else { nil }
                    })
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(CleanupCopy.openTrash) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: environment.home + "/.Trash"))
                }
                Button(CleanupCopy.showAuditLog) {
                    NSWorkspace.shared.activateFileViewerSelecting([AuditLog.defaultURL(environment: environment)])
                }
                Spacer()
                Button(CleanupCopy.done) { onDone(trashedIDs) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 240)
        .onAppear { AccessibilityNotification.Announcement(summaryLine).post() }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(CleanupCopy.sectionHeading(title, count: rows.count)).font(.headline)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Text(r.0).lineLimit(1).truncationMode(.middle)
                    Text(r.1).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
