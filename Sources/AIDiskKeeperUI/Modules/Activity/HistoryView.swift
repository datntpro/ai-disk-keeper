import AppKit
import DiskKeeperCore
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @Bindable var model: HistoryModel
    let coordinator: CleanupCoordinator
    @State private var exportError = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { model.load() }
        .onChange(of: coordinator.isPresented) { _, presented in if !presented { model.load() } }
        .alert(HistoryCopy.exportFailed, isPresented: $exportError) {}
    }

    private var header: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(HistoryCopy.title).font(.headline)
                Text(HistoryCopy.lifetime).font(.caption).foregroundStyle(.adkText3)
            }
            Text(Formatting.bytes(model.lifetimeReclaimed)).font(.title2.weight(.semibold)).monospacedDigit()
                .accessibilityLabel(HistoryCopy.a11yLifetime(Formatting.bytes(model.lifetimeReclaimed)))
            Spacer()
            Button(HistoryCopy.revealLog) { model.revealLog() }
            Button(HistoryCopy.exportCSV) { export() }.disabled(model.history.entries.isEmpty)
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            StateView(kind: .progress(nil), symbol: "clock.arrow.circlepath", title: HistoryCopy.title, message: HistoryCopy.loading)
        case .failed:
            StateView(kind: .error, symbol: "exclamationmark.triangle", title: HistoryCopy.failedTitle, message: "",
                      actions: [StateAction(title: HistoryCopy.retry) { model.load() }])
        case .ready:
            VStack(spacing: 0) {
                if model.unreadableCount > 0 { banner(HistoryCopy.unreadable(model.unreadableCount)) }
                if model.history.truncatedHead { banner(HistoryCopy.truncated) }
                if model.runs.isEmpty {
                    StateView(kind: .empty, symbol: "clock.arrow.circlepath", title: HistoryCopy.emptyTitle, message: HistoryCopy.emptyMessage)
                } else {
                    HStack(spacing: 0) {
                        runList.frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                        Divider()
                        detail.frame(minWidth: 380, maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func banner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.adkReviewInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.sm)
            .background(Color.adkReviewSoft)
    }

    private var runList: some View {
        List(model.runs, selection: $model.selectedRunID) { run in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Formatting.absolute(run.date)).font(.body)
                    Spacer()
                    if run.failedCount > 0 {
                        Label(Formatting.count(run.failedCount), systemImage: "xmark.octagon").font(.caption).foregroundStyle(.adkDangerInk)
                            .accessibilityLabel(HistoryCopy.a11yFailed(run.failedCount))
                    }
                }
                Text(run.kind == .quit ? HistoryCopy.quitApp : HistoryCopy.runSummary(HistoryCopy.items(run.itemCount), HistoryCopy.runBytes(Formatting.bytes(run.reclaimedBytes))))
                    .font(.caption).foregroundStyle(.adkText3)
            }
            .tag(run.id)
        }
    }

    @ViewBuilder private var detail: some View {
        if let run = model.selectedRun {
            List {
                if run.kind == .quit {
                    ForEach(Array(run.quitEvents.enumerated()), id: \.offset) { _, q in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.appPath).lineLimit(1).truncationMode(.middle)
                            Text(HistoryCopy.quitResult(q.result ?? q.phase)).font(.caption).foregroundStyle(.adkText3)
                        }
                    }
                } else {
                    ForEach(Array(run.records.enumerated()), id: \.offset) { _, r in row(r) }
                }
            }
        } else {
            StateView(kind: .empty, symbol: "clock.arrow.circlepath", title: HistoryCopy.title, message: HistoryCopy.selectRun)
        }
    }

    private func row(_ r: AuditRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.path).lineLimit(1).truncationMode(.middle).help(r.path)
                HStack(spacing: ADKTheme.Spacing.sm) {
                    Text(Self.resultTitle(r.result)).font(.caption).foregroundStyle(.adkText2)
                    if !r.reasons.isEmpty { Text(r.reasons.joined(separator: ", ")).font(.caption).foregroundStyle(.adkText3) }
                    if let e = r.error { Text(e).font(.caption).foregroundStyle(.adkDangerInk).lineLimit(1) }
                }
            }
            Spacer()
            Text(Formatting.bytes(r.bytes)).monospacedDigit().foregroundStyle(.adkText2)
            if r.result == "trashed" {
                let ok = model.canRevealInTrash(r)
                Button(HistoryCopy.revealInTrash) { model.revealInTrash(r) }
                    .disabled(!ok).help(ok ? "" : HistoryCopy.notInTrash)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func resultTitle(_ result: String) -> String {
        switch result {
        case "trashed": HistoryCopy.resultTrashed
        case "deleted": HistoryCopy.resultDeleted
        case "ran": HistoryCopy.resultRan
        case "skipped": HistoryCopy.resultSkipped
        case "failed": HistoryCopy.resultFailed
        default: HistoryCopy.resultOther
        }
    }

    private func export() {
        let csv = model.csv()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "cleanup-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { exportError = true }
    }
}
