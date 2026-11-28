import DiskKeeperCore
import SwiftUI

/// The worktree inventory: read-only. Columns, filters, and an inspector that lists every safety check.
struct WorktreeManagerView: View {
    @Bindable var model: WorktreeManagerModel
    private var consent: GitHubConsentModel { model.consent }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            warnings
            content
        }
        .task { model.refreshIfNeeded() }
        .sheet(isPresented: Bindable(consent).isSheetShown) { GitHubConsentSheet(consent: consent) }
    }

    private var toolbar: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            Picker(selection: $model.filter) {
                ForEach(WorktreeFilter.allCases) { Text($0.title).tag($0) }
            } label: { EmptyView() }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            Spacer()
            GitHubCLIToggle(consent: consent)
            Button { model.refresh() } label: { Label(WorktreeCopy.refresh, systemImage: "arrow.clockwise") }
                .disabled(model.phase == .loading)
            Button(WorktreeCopy.selectSafe) {}
                .disabled(!model.canSelectSafe)
                .help(WorktreeCopy.selectSafeHelp)
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.sm)
    }

    @ViewBuilder private var warnings: some View {
        if let result = model.result, !result.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, w in
                    Label(WorktreeCopy.warning(w), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.adkReviewInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.xs)
            .background(.adkReviewSoft)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading where model.result == nil:
            StateView(kind: .progress(nil), symbol: "arrow.triangle.branch", title: WorktreeCopy.loading, message: "")
        default:
            if model.rows.isEmpty {
                StateView(kind: .empty, symbol: "arrow.triangle.branch", title: WorktreeCopy.emptyTitle, message: WorktreeCopy.emptyMessage)
            } else if model.visibleRows.isEmpty {
                StateView(kind: .filteredEmpty, symbol: "line.3.horizontal.decrease.circle", title: WorktreeCopy.filteredEmptyTitle, message: "")
            } else {
                // Not an HSplitView: nested inside the app's own split view it produced an unsatisfiable width and an
                // AppKit constraint-loop crash when the sidebar was collapsed.
                HStack(spacing: 0) {
                    table.frame(minWidth: 0, maxWidth: .infinity)
                    Divider()
                    WorktreeInspector(row: model.selectedRow).frame(width: 300)
                }
            }
        }
    }

    private var table: some View {
        Table(model.visibleRows, selection: $model.selection) {
            TableColumn(WorktreeCopy.colName) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name).lineLimit(1)
                    Text(row.repoName).font(.caption).foregroundStyle(.adkText3).lineLimit(1)
                }
            }
            .width(min: 100, ideal: 150)
            TableColumn(WorktreeCopy.colVerdict) { row in WorktreeVerdictChip(verdict: row.verdict) }
                .width(min: 110, ideal: 150)
            TableColumn(WorktreeCopy.colBranch) { row in
                Text(branch(row)).font(.callout).foregroundStyle(.adkText2).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 60, ideal: 100)
            TableColumn(WorktreeCopy.colSize) { row in
                Text(row.facts.allocatedBytes.map { Formatting.bytes($0) } ?? WorktreeCopy.dash).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn(WorktreeCopy.colPR) { row in Text(prText(row.facts.pr)).font(.callout) }
                .width(min: 70, ideal: 90)
            TableColumn(WorktreeCopy.colChanges) { row in Text(changesText(row)).font(.callout) }
                .width(min: 60, ideal: 80)
            TableColumn(WorktreeCopy.colProcesses) { row in Text(processText(row)).font(.callout).lineLimit(1) }
                .width(min: 70, ideal: 110)
            TableColumn(WorktreeCopy.colActivity) { row in
                Text(row.facts.lastActivity.map { Formatting.relative($0.date) } ?? WorktreeCopy.dash).font(.callout)
            }
            .width(min: 70, ideal: 90)
        }
    }

    private func branch(_ row: WorktreeRow) -> String {
        if case .branch(let name, _) = row.facts.git?.head { return name }
        return row.facts.worktree.branch ?? (row.facts.git?.head == nil ? WorktreeCopy.dash : "HEAD")
    }

    private func prText(_ pr: PRState) -> String {
        switch pr {
        case .merged(let n, _, _): WorktreeCopy.prMerged(n)
        case .closed(let n, _): WorktreeCopy.prClosed(n)
        case .open(let n, _): WorktreeCopy.prOpen(n)
        case .none: WorktreeCopy.prNone
        case .unknown: WorktreeCopy.prUnknown
        case .disabled: WorktreeCopy.prOff
        }
    }

    private func changesText(_ row: WorktreeRow) -> String {
        guard let wt = row.facts.git?.workingTree else { return WorktreeCopy.dash }
        return wt.isClean ? WorktreeCopy.changesClean : WorktreeCopy.changesFiles(wt.staged + wt.unstaged + wt.untracked + wt.conflicted)
    }

    private func processText(_ row: WorktreeRow) -> String {
        guard let procs = row.facts.processes else { return WorktreeCopy.dash }
        if procs.isEmpty { return WorktreeCopy.dash }
        let agents = Set(procs.compactMap { $0.agent?.rawValue }).sorted()
        return agents.isEmpty ? Formatting.count(procs.count) : "\(Formatting.count(procs.count)) · \(agents.joined(separator: ", "))"
    }
}

/// ✓ Safe to clean, or the first failing check as a chip.
struct WorktreeVerdictChip: View {
    let verdict: SafeCleanVerdict

    var body: some View {
        let (text, symbol, ink, soft) = style
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold)).lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(soft, in: Capsule())
            .accessibilityElement(children: .combine)
    }

    private var style: (String, String, Color, Color) {
        if verdict.eligible { return (WorktreeCopy.safe, "checkmark.circle.fill", .adkSafeInk, .adkSafeSoft) }
        let name = verdict.firstBlocker.map { WorktreeCopy.checkName($0.id) } ?? WorktreeCopy.review
        switch verdict.tier {
        case .keep: return (name, "hand.raised.fill", .adkKeepInk, .adkKeepSoft)
        default: return (name, "questionmark.circle.fill", .adkReviewInk, .adkReviewSoft)
        }
    }
}

struct GitHubCLIToggle: View {
    let consent: GitHubConsentModel

    var body: some View {
        Toggle(WorktreeCopy.ghToggle, isOn: Binding(get: { consent.isOn }, set: { consent.request($0) }))
            .toggleStyle(.switch).controlSize(.small)
            .help(WorktreeCopy.ghToggleHelp)
    }
}

struct GitHubConsentSheet: View {
    let consent: GitHubConsentModel

    var body: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
            Text(WorktreeCopy.ghConsentTitle).font(.headline)
            Text(WorktreeCopy.ghConsentMessage).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(WorktreeCopy.ghConsentCancel) { consent.cancel() }.keyboardShortcut(.cancelAction)
                Button(WorktreeCopy.ghConsentAllow) { consent.confirm() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(ADKTheme.Spacing.xl).frame(width: 420)
    }
}
