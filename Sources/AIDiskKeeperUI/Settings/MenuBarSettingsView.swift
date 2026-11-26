import DiskKeeperCore
import SwiftUI

/// Settings → Menu bar: the T47 toggles (moved here, same keys) and the system monitor options.
struct MenuBarSettingsView: View {
    let model: SettingsModel

    private var s: AppSettings { model.settings }
    private var on: Bool { s.showMenuBarItem }

    var body: some View {
        Form {
            Section(loc("settings.menubar.section", "Menu bar")) {
                Toggle(loc("settings.menubar.show", "Show in menu bar"), isOn: Binding(
                    get: { s.showMenuBarItem }, set: { model.setShowMenuBarItem($0) }))
                Toggle(loc("settings.menubar.freeText", "Show free space next to the icon"), isOn: Binding(
                    get: { s.menuBarShowsFreeSpace }, set: { model.setMenuBarShowsFreeSpace($0) }))
                    .disabled(!on)
                Toggle(loc("settings.menubar.lowSpace", "Alert me when free space is low"), isOn: Binding(
                    get: { s.lowSpaceAlertEnabled }, set: { model.setLowSpaceAlertEnabled($0) }))
                if s.lowSpaceAlertEnabled {
                    Stepper(loc("settings.menubar.threshold", "Below \(Formatting.count(s.lowSpaceThresholdPercent)) %"),
                            value: Binding(get: { s.lowSpaceThresholdPercent }, set: { model.setLowSpaceThresholdPercent($0) }),
                            in: AppSettings.lowSpaceThresholdRange)
                    Text(loc("settings.menubar.thresholdHelp", "One notification each time free space drops below this level."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(SystemMonitorCopy.monitorGroup) {
                if !on {
                    Text(SystemMonitorCopy.needsItem).font(.caption).foregroundStyle(.secondary)
                }
                styleGroup
                metricsGroup
                refreshGroup
            }
            .disabled(!on)
        }
        .formStyle(.grouped)
    }

    // MARK: Style + width preview

    private var styleGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(SystemMonitorCopy.style, selection: Binding(get: { s.menuBarStyle }, set: { model.setMenuBarStyle($0) })) {
                ForEach(MenuBarStyle.allCases, id: \.self) { Text(SystemMonitorCopy.styleName($0)).tag($0) }
            }
            Text(SystemMonitorCopy.styleNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let layout = MenuBarLayout.preview(s)
            Text(SystemMonitorCopy.widthPreview(Formatting.count(Int(layout.width)), Formatting.count(Int(MenuBarLayout.budget))))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            let stepped = MenuBarLayout.steppedDown(layout, style: s.menuBarStyle)
            if s.menuBarStyle != .glyph {
                let name = SystemMonitorCopy.layoutName(MenuBarLayout.layoutName(layout))
                Text(stepped ? SystemMonitorCopy.layoutLineWhy(name) : SystemMonitorCopy.layoutLine(name))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if stepped {
                Text(SystemMonitorCopy.steppedDown).font(.caption).foregroundStyle(Color.adkReviewInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Metrics (order, monitor, in bar)

    private var metricsGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SystemMonitorCopy.metrics).font(.headline)
            ForEach(Array(s.monitorOrder.enumerated()), id: \.element) { index, metric in
                metricRow(metric, index: index)
            }
            Text(SystemMonitorCopy.diskAlways).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metricRow(_ metric: MetricID, index: Int) -> some View {
        HStack {
            VStack(spacing: 0) {
                Button { model.moveMetric(metric, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { model.moveMetric(metric, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == s.monitorOrder.count - 1)
            }
            .buttonStyle(.borderless).controlSize(.mini)
            .accessibilityHidden(true)
            Text(SystemMonitorCopy.title(metric))
            Spacer()
            Toggle(SystemMonitorCopy.monitor, isOn: Binding(get: { s.isMonitored(metric) }, set: { model.setMetric(metric, monitored: $0) }))
                .disabled(metric == .disk)
            Toggle(SystemMonitorCopy.inMenuBar, isOn: Binding(get: { s.isInMenuBar(metric) }, set: { model.setMetric(metric, inMenuBar: $0) }))
                .disabled(!s.isMonitored(metric))
        }
        .toggleStyle(.checkbox)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SystemMonitorCopy.title(metric))
        .accessibilityAction(named: SystemMonitorCopy.moveUp) { model.moveMetric(metric, by: -1) }
        .accessibilityAction(named: SystemMonitorCopy.moveDown) { model.moveMetric(metric, by: 1) }
    }

    // MARK: Refresh, units, processes

    private var refreshGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(SystemMonitorCopy.refresh, selection: Binding(get: { s.menuBarRefreshSeconds }, set: { model.setMenuBarRefresh(seconds: $0) })) {
                ForEach(SamplingPolicy.barIntervalChoices, id: \.self) { Text(SystemMonitorCopy.refreshEvery(Formatting.count($0))).tag($0) }
            }
            Picker(SystemMonitorCopy.units, selection: Binding(get: { s.networkUnits }, set: { model.setNetworkUnits($0) })) {
                Text(SystemMonitorCopy.unitsBytes).tag(NetworkUnits.bytes)
                Text(SystemMonitorCopy.unitsBits).tag(NetworkUnits.bits)
            }
            Toggle(SystemMonitorCopy.topProcessesToggle, isOn: Binding(get: { s.popoverShowsTopProcesses }, set: { model.setShowsTopProcesses($0) }))
            Text(SystemMonitorCopy.topProcessesNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
