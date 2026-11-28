import DiskKeeperCore
import SwiftUI

/// Every check with ✓ / ✗ / ? and its evidence, plus what runs in the worktree.
struct WorktreeInspector: View {
    let row: WorktreeRow?

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    Text(row.name).font(ADKTheme.Font.title)
                    WorktreeVerdictChip(verdict: row.verdict)
                    Group {
                        Text(WorktreeCopy.inspectorPath).font(.caption).foregroundStyle(.adkText3)
                        Text(row.path).font(ADKTheme.Font.path).textSelection(.enabled)
                    }
                    if let pr = row.facts.worktree.orca?.linkedPR {
                        Text(WorktreeCopy.orcaPR(pr)).font(.caption).foregroundStyle(.adkText3)
                    }
                    Divider()
                    Text(WorktreeCopy.inspectorChecks).font(.headline)
                    ForEach(row.verdict.checks, id: \.id) { check in checkRow(check) }
                    if let a = row.facts.lastActivity {
                        Text(activityLine(a))
                            .font(.caption).foregroundStyle(.adkText2)
                    }
                    if let procs = row.facts.processes, !procs.isEmpty {
                        Divider()
                        Text(WorktreeCopy.inspectorProcesses).font(.headline)
                        ForEach(procs, id: \.pid) { p in
                            Text(processLine(p)).font(.callout)
                        }
                    }
                    Text(WorktreeCopy.inspectorHint).font(.caption).foregroundStyle(.adkText3)
                }
                .padding(ADKTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            StateView(kind: .empty, symbol: "sidebar.right", title: WorktreeCopy.selectOne, message: "")
        }
    }

    private func checkRow(_ c: WorktreeCheck) -> some View {
        let (symbol, ink): (String, Color) = switch c.passed {
        case true: ("checkmark.circle.fill", .adkSafeInk)
        case false: ("xmark.circle.fill", .adkDangerInk)
        default: ("questionmark.circle.fill", .adkReviewInk)
        }
        let state = c.passed == true ? WorktreeCopy.passed : (c.passed == false ? WorktreeCopy.failed : WorktreeCopy.unknownCheck)
        let label = [WorktreeCopy.checkName(c.id), state, WorktreeCopy.evidence(c.evidence)].joined(separator: ", ")
        return HStack(alignment: .top, spacing: ADKTheme.Spacing.sm) {
            Image(systemName: symbol).foregroundStyle(ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(WorktreeCopy.checkName(c.id)).font(.callout.weight(.medium))
                Text(WorktreeCopy.evidence(c.evidence)).font(.caption).foregroundStyle(.adkText2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func activityLine(_ a: WorktreeActivity) -> String {
        [WorktreeCopy.inspectorActivity(WorktreeCopy.source(a.source)), Formatting.absolute(a.date)].joined(separator: ": ")
    }

    private func processLine(_ p: WorktreeProcess) -> String {
        ([p.name, String(p.pid)] + (p.agent.map { [$0.rawValue] } ?? [])).joined(separator: " · ")
    }
}
