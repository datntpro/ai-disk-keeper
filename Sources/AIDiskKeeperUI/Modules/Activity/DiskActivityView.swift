import DiskKeeperCore
import SwiftUI

struct DiskActivityView: View {
    let model: DiskActivityModel

    var body: some View {
        Group {
            if let snap = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: ADKTheme.Spacing.lg) {
                        header(snap)
                        worktreeTable(snap)
                        agentTable(snap)
                        processTable(snap)
                        if snap.processes.contains(where: { $0.kind == .spotlight || $0.kind == .defender }) {
                            Label(DiskActivityCopy.spotlightNote, systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.adkText2)
                        }
                    }
                    .padding(ADKTheme.Spacing.lg)
                }
            } else {
                StateView(kind: .progress(nil), symbol: "internaldrive", title: DiskActivityCopy.emptyTitle,
                          message: DiskActivityCopy.emptyMessage)
            }
        }
        .onAppear { model.setModuleVisible(true) }
        .onDisappear { model.setModuleVisible(false) }
    }

    private func header(_ snap: HostLoadSnapshot) -> some View {
        let now = SystemMonitorModel.defaultClock()
        return SectionCard {
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                if let disk = snap.disk {
                    HStack(alignment: .firstTextBaseline, spacing: ADKTheme.Spacing.lg) {
                        stat(DiskActivityCopy.diskWrites, MonitorFormatting.rate(disk.writeBytesPerSec, units: .bytes))
                        stat(DiskActivityCopy.diskReads, MonitorFormatting.rate(disk.readBytesPerSec, units: .bytes))
                        stat(DiskActivityCopy.busy, MonitorFormatting.percent(disk.busyFraction))
                        Spacer()
                    }
                    Sparkline(samples: model.writeHistory.window(DiskActivityModel.historyWindow, now: now), now: now,
                              window: DiskActivityModel.historyWindow, yMax: nil, floor: 1_000_000, gap: 30, height: 40)
                    if let other = snap.unattributedWriteBytesPerSec {
                        Text(verbatim: "\(DiskActivityCopy.other): \(MonitorFormatting.rate(other, units: .bytes))")
                            .font(.caption).foregroundStyle(.adkText2)
                    }
                } else {
                    Text(DiskActivityCopy.unavailable).foregroundStyle(.adkText2)
                }
                Text(DiskActivityCopy.load(String(format: "%.1f", snap.loadAverage.0), snap.cpuCount))
                    .font(.caption).foregroundStyle(.adkText3)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.adkText2)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func worktreeTable(_ snap: HostLoadSnapshot) -> some View {
        section(DiskActivityCopy.byWorktree) {
            Table(snap.byWorktree) {
                TableColumn(DiskActivityCopy.colWorktree) { r in
                    Text(r.worktree.displayName).lineLimit(1).help(r.worktree.root)
                }
                TableColumn(DiskActivityCopy.colWrites) { r in rate(r.writeBytesPerSec) }.width(90)
                TableColumn(DiskActivityCopy.colReads) { r in rate(r.readBytesPerSec) }.width(90)
                TableColumn(DiskActivityCopy.colProcesses) { r in Text(Formatting.count(r.processCount)).monospacedDigit() }.width(80)
                TableColumn(DiskActivityCopy.colAgents) { r in
                    Text(r.agents.map(DiskActivityCopy.kindName).joined(separator: ", ")).lineLimit(1).foregroundStyle(.adkText2)
                }
            }
            .frame(height: tableHeight(snap.byWorktree.count))
        }
    }

    private func agentTable(_ snap: HostLoadSnapshot) -> some View {
        section(DiskActivityCopy.byAgent) {
            Table(snap.byAgent) {
                TableColumn(DiskActivityCopy.colAgent) { r in Text(DiskActivityCopy.kindName(r.kind)) }
                TableColumn(DiskActivityCopy.colWrites) { r in rate(r.writeBytesPerSec) }.width(90)
                TableColumn(DiskActivityCopy.colReads) { r in rate(r.readBytesPerSec) }.width(90)
                TableColumn(DiskActivityCopy.colProcesses) { r in Text(Formatting.count(r.processCount)).monospacedDigit() }.width(80)
            }
            .frame(height: tableHeight(snap.byAgent.count))
        }
    }

    private func processTable(_ snap: HostLoadSnapshot) -> some View {
        section(DiskActivityCopy.topProcesses) {
            Table(snap.processes) {
                TableColumn(DiskActivityCopy.colProcess) { r in Text(verbatim: r.name).lineLimit(1) }
                TableColumn(DiskActivityCopy.colAgent) { r in
                    Text(verbatim: r.agent.map(DiskActivityCopy.kindName) ?? "—").foregroundStyle(.adkText2)
                }.width(110)
                TableColumn(DiskActivityCopy.colWorktree) { r in
                    Text(verbatim: r.worktree?.displayName ?? "—").lineLimit(1).foregroundStyle(.adkText2).help(r.worktree?.root ?? DiskActivityCopy.noAttribution)
                }
                TableColumn(DiskActivityCopy.colWrites) { r in rate(r.writeBytesPerSec) }.width(90)
                TableColumn(DiskActivityCopy.colReads) { r in rate(r.readBytesPerSec) }.width(90)
                TableColumn(DiskActivityCopy.colWritten) { r in Text(Formatting.bytes(Int64(clamping: r.totalBytesWritten))).monospacedDigit() }.width(120)
            }
            .frame(height: tableHeight(snap.processes.count))
        }
    }

    private func rate(_ v: Double) -> some View {
        Text(verbatim: v < 1 ? "—" : MonitorFormatting.rate(v, units: .bytes)).monospacedDigit()
    }

    private func tableHeight(_ rows: Int) -> CGFloat { CGFloat(min(max(rows, 1), 12)) * 24 + 32 }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            Text(title).font(.headline)
            content()
        }
    }
}
