import AppKit
import DiskKeeperCore
import SwiftUI

/// The menu bar popover (300 pt). Report-only: the one way to act on results is "Review in app", which opens the
/// window on Overview, where every cleanup still goes through the dry-run sheet. There is no cleanup path here.
struct MenuBarPopover: View {
    let model: MenuBarModel
    let suite: SuiteModel
    var open: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            volumeRow
            Divider()
            scanSummary
            if !model.topTools.isEmpty { topTools }
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
        .frame(width: 300)
        .background(Color.adkBg)
        .tint(.adkAccent)
        .environment(\.locale, L10n.locale)
        .onAppear { model.popoverOpened() }
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

    private var topTools: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MenuBarCopy.topTools).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
