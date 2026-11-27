import AppKit
import DiskKeeperCore
import SwiftUI

/// Counts body evaluations so a test can prove a closed popover does no view work.
@MainActor enum PopoverProbe {
    static var shellEvaluations = 0
    static var contentEvaluations = 0
}

/// The menu bar popover (320 pt). Report-only: the one way to act on results is "Review in app", which opens the
/// window on Overview, where every cleanup still goes through the dry-run sheet. There is no cleanup path here.
struct MenuBarPopover: View {
    let model: MenuBarModel
    let monitor: SystemMonitorModel
    let suite: SuiteModel
    var hostLoad: DiskActivityModel?
    var open: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    /// Only the shell lives while the popover is closed. The hidden MenuBarExtra window keeps its view tree, and every
    /// view in it that reads an observable model is laid out again on each tick, so the content exists only while open.
    var body: some View {
        PopoverProbe.shellEvaluations += 1
        return Group {
            if monitor.popoverOpen { content }
        }
        .frame(width: 320)
        .background(WindowAccessor { monitor.popoverWindow = $0 })
        .onAppear { model.popoverOpened(); monitor.setPopoverOpen(true); hostLoad?.setPopoverOpen(true) }
        .onDisappear { monitor.setPopoverOpen(false); hostLoad?.setPopoverOpen(false) }
    }

    private var content: some View {
        PopoverProbe.contentEvaluations += 1
        return VStack(alignment: .leading, spacing: 12) {
            volumeRow
            Divider()
            scanSummary
            if !model.topTools.isEmpty { topTools }
            if !monitor.settings.settings.enabledMetricsInOrder.filter({ $0 != .disk }).isEmpty {
                Divider()
                SystemMonitorSection(monitor: monitor)
            }
            if let text = model.trendText { trendRow(text) }
            if let hostLoad, !hostLoad.topWorktrees.isEmpty { diskActivity(hostLoad) }
            if let next = model.nextScheduledScan {
                Text(MenuBarCopy.nextScan(Formatting.absolute(next))).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            actions
            Divider()
            Button(MenuBarCopy.quit) { NSApp.terminate(nil) }
                .buttonStyle(.plain).keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
        .background(Color.adkBg)
        .tint(.adkAccent)
        .environment(\.locale, L10n.locale)
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Gauge(value: model.usedFraction ?? 0) {
                Text(verbatim: model.volumeName)
            } currentValueLabel: {
                Text(verbatim: model.usedFraction.map { MenuBarCopy.usedPercent(Formatting.count(Int(($0 * 100).rounded()))) } ?? "—")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.adkAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.volumeName).font(.headline)
                Text(verbatim: model.freeBytes.map { MenuBarCopy.free(Formatting.bytes($0)) } ?? "—")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var scanSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isScanning {
                Text(MenuBarCopy.scanning).foregroundStyle(.secondary)
            } else if let safe = model.safeBytes {
                Text(MenuBarCopy.safe(Formatting.bytes(safe))).font(.headline).foregroundStyle(Color.adkSafeInk)
                if let at = model.lastScanAt {
                    Text(MenuBarCopy.scanned(Formatting.relative(at))).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(MenuBarCopy.notScanned).foregroundStyle(.secondary)
            }
            if let delta = model.aiGrowth {
                Text(delta > 0 ? MenuBarCopy.growth(Formatting.bytes(delta)) : MenuBarCopy.growthDown(Formatting.bytes(delta)))
                    .font(.callout)
            }
            if let top = model.topSafeModule {
                Text(MenuBarCopy.topModule(OverviewTarget.title(for: top.module), Formatting.bytes(top.bytes)))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func trendRow(_ text: String) -> some View {
        Label(text, systemImage: model.trend?.timeToFull == nil ? "equal.circle" : "chart.line.downtrend.xyaxis")
            .font(.callout).foregroundStyle(model.freeSpaceLevel == .ok ? Color.secondary : Color.adkReviewInk)
            .accessibilityElement(children: .combine)
    }

    /// The three worktrees writing the most; a click opens the Disk Activity screen. Report-only.
    private func diskActivity(_ hostLoad: DiskActivityModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DiskActivityCopy.popoverTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(hostLoad.topWorktrees) { row in
                Button { openDiskActivity() } label: {
                    HStack {
                        Text(verbatim: row.worktree.displayName).lineLimit(1)
                        Spacer()
                        Text(verbatim: MonitorFormatting.rate(row.writeBytesPerSec, units: .bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func openDiskActivity() {
        suite.navigation.selection = .module(.diskActivity)
        monitor.popoverWindow?.close()   // the popover must not stay open over the window
        openWindow(id: "main")
        NSApp.activate()
        open()
    }

    private var topTools: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MenuBarCopy.topTools).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(MenuBarCopy.topToolsNote).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.topTools, id: \.tool) { row in
                HStack {
                    Text(verbatim: row.tool.uiName)
                    Spacer()
                    Text(verbatim: Formatting.bytes(row.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .help(MenuBarCopy.topToolsNote)
    }

    private var actions: some View {
        HStack {
            Button(MenuBarCopy.reviewInApp) { reviewInApp() }
                .buttonStyle(.borderedProminent)
            if model.care.isBusy {
                Button(OverviewCopy.buttonStop) { model.care.stop() }
            } else {
                Button(MenuBarCopy.scanNow) { model.care.start() }.disabled(model.isScanning)
            }
        }
    }

    private func reviewInApp() {
        suite.navigation.selection = .overview
        openWindow(id: "main")
        NSApp.activate()
        open()
    }
}
