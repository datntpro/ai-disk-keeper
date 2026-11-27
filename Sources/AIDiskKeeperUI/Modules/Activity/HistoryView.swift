import AppKit
import DiskKeeperCore
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @Bindable var model: HistoryModel
    let coordinator: CleanupCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await model.refresh() }
        .onChange(of: coordinator.lastReport == nil ? 0 : 1) { Task { await model.refresh() } }
        .onChange(of: coordinator.isPresented) { _, shown in if !shown { Task { await model.refresh() } } }
    }

    private var header: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            SectionCard(padding: ADKTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HistoryCopy.lifetime).font(.callout).foregroundStyle(.adkText2)
                    Text(Formatting.bytes(model.lifetimeReclaimed)).font(.title.weight(.semibold)).foregroundStyle(.adkText)
                }
                .accessibilityElement(children: .combine)
            }
            .fixedSize()
            Spacer()
            Picker(ProcessControlCopy.historyFilterLabel, selection: $model.filter) {
                Text(ProcessControlCopy.historyFilterAll).tag(HistoryModel.Filter.all)
                Text(ProcessControlCopy.historyFilterProcesses).tag(HistoryModel.Filter.processes)
            }
            .pickerStyle(.segmented).fixedSize()
            Button(HistoryCopy.revealLog) { model.revealLog() }
            Button { exportCSV() } label: { Label(HistoryCopy.exportCSV, systemImage: "square.and.arrow.up") }
                .disabled(model.runs.isEmpty)
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            StateView(kind: .progress(nil), symbol: "clock.arrow.circlepath", title: HistoryCopy.lifetime, message: "")
        case .failed(let reason):
            StateView(kind: .blockingError, symbol: "exclamationmark.triangle", title: HistoryCopy.loadFailedTitle, message: reason)
        case .ready:
            VStack(spacing: 0) {
                if model.history.malformedLines + model.history.unknownLines > 0 {
                    Label(HistoryCopy.entriesUnreadable(model.history.malformedLines + model.history.unknownLines), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.adkReviewInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.sm)
                        .background(.adkReviewSoft)
                }
                if model.history.truncatedHead {
                    Label(HistoryCopy.truncated, systemImage: "info.circle").font(.caption).foregroundStyle(.adkText2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, ADKTheme.Spacing.lg)
                }
                if model.runs.isEmpty {
                    StateView(kind: .empty, symbol: "clock.arrow.circlepath", title: HistoryCopy.emptyTitle, message: HistoryCopy.emptyMessage)
                } else {
                    HSplitView { runList.frame(minWidth: 260, idealWidth: 300); detail.frame(minWidth: 360) }
                }
            }
        }
    }

    private var runList: some View {
        List(model.runs, selection: $model.selectedRunID) { run in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatting.absolute(run.date)).font(.body)
                    Text(HistoryCopy.run(run)).font(.caption).foregroundStyle(.adkText3)
                }
                Spacer()
                if run.failed > 0 {
                    Text(HistoryCopy.failedCount(run.failed)).font(.caption).foregroundStyle(.adkDangerInk)
                }
                if run.kind == .cleanup { Text(Formatting.bytes(run.bytesReclaimed)).monospacedDigit().foregroundStyle(.adkText2) }
            }
            .tag(run.id)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var detail: some View {
        if let run = model.selectedRun {
            if run.kind == .processControl {
                Table(run.processes.sorted { $0.timestamp < $1.timestamp }, columns: {
                    TableColumn(ProcessControlCopy.colProcess) { p in Text(verbatim: "\(p.name) (\(p.pid))").lineLimit(1) }
                    TableColumn(HistoryCopy.colActions) { p in Text(ProcessControlCopy.historyAction(p.action)) }.width(130)
                    TableColumn(HistoryCopy.colResult) { p in Text(ProcessControlCopy.historyResult(p.result)) }.width(100)
                    TableColumn(HistoryCopy.colReason) { p in
                        Text(verbatim: [p.root.map { "↳ \($0)" }, p.result.hasPrefix("refused:") ? String(p.result.dropFirst(8)) : nil,
                                        p.errno.map { "errno \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .lineLimit(1).foregroundStyle(.adkText2)
                    }
                })
            } else if run.kind == .appQuit {
                List(Array(run.quits.enumerated()), id: \.offset) { _, q in
                    HStack { Text(q.appPath).lineLimit(1).truncationMode(.middle); Spacer(); Text(q.result ?? q.phase).foregroundStyle(.adkText2) }
                }
            } else {
                Table(run.records) {
                    TableColumn(HistoryCopy.colPath) { r in Text(r.path).lineLimit(1).truncationMode(.middle).help(r.path) }
                    TableColumn(HistoryCopy.colSize) { r in Text(Formatting.bytes(r.bytes)).monospacedDigit() }.width(90)
                    TableColumn(HistoryCopy.colResult) { r in Text(HistoryCopy.result(r.result)) }.width(130)
                    TableColumn(HistoryCopy.colReason) { r in Text(r.error ?? r.reasons.joined(separator: ", ")).lineLimit(1).foregroundStyle(.adkText2) }
                    TableColumn(HistoryCopy.colActions) { r in
                        if r.trashPath != nil {
                            let ok = model.canRevealInTrash(r)
                            Button(HistoryCopy.revealInTrash) { model.revealInTrash(r) }
                                .disabled(!ok).help(ok ? "" : HistoryCopy.notInTrash)
                        }
                    }.width(130)
                }
            }
        } else {
            StateView(kind: .empty, symbol: "list.bullet", title: HistoryCopy.selectRun, message: "")
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = HistoryCopy.csvName + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.csvData().write(to: url, options: .atomic) } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = HistoryCopy.exportFailed
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension AuditRecord: @retroactive Identifiable {
    public var id: String { "\(runID)|\(timestamp.timeIntervalSince1970)|\(path)|\(result)" }
}

extension ProcessControlAuditRecord: @retroactive Identifiable {
    public var id: String { "\(flowID)|\(pid)|\(timestamp.timeIntervalSince1970)|\(action)" }
}
