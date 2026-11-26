import AppKit
import DiskKeeperCore
import SwiftUI

/// Captures the hosting window so a missed `.onDisappear` can't leave the 2 s sampling on.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// The popover's System block: one card per enabled metric (disk stays in the T47 block above), in the user's order.
struct SystemMonitorSection: View {
    let monitor: SystemMonitorModel

    var body: some View {
        let s = monitor.settings.settings
        VStack(alignment: .leading, spacing: 10) {
            header(s)
            ForEach(s.enabledMetricsInOrder.filter { $0 != .disk }, id: \.self) { m in
                switch m {
                case .cpu: cpuCard
                case .memory: memoryCard
                case .network: networkCard(s.networkUnits)
                case .disk: EmptyView()
                }
            }
            if s.popoverShowsTopProcesses { TopProcessesView(monitor: monitor) }
        }
    }

    private func header(_ s: AppSettings) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.adkSafe).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(SystemMonitorCopy.section).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(SystemMonitorCopy.every("2")).font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Picker(selection: Binding(get: { s.popoverHistoryMinutes }, set: { monitor.settings.setHistoryMinutes($0) })) {
                Text(SystemMonitorCopy.window1).tag(1)
                Text(SystemMonitorCopy.window5).tag(5)
            } label: { Text(SystemMonitorCopy.section) }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var windowLong: String {
        monitor.settings.settings.popoverHistoryMinutes == 5 ? SystemMonitorCopy.window5Long : SystemMonitorCopy.window1Long
    }

    // MARK: Cards

    private var cpuCard: some View {
        let id = SystemMonitorModel.SeriesID.cpu
        let st = monitor.stats(id)
        return MetricCard(title: SystemMonitorCopy.title(.cpu),
                          value: monitor.cpu.value.map { MonitorFormatting.percent($0.total) },
                          a11yValue: monitor.cpu.value.map {
                              SystemMonitorCopy.cardA11y(value: SystemMonitorCopy.percentSpoken(MonitorFormatting.percentNumber($0.total)),
                                                         average: SystemMonitorCopy.percentSpoken(MonitorFormatting.percentNumber(st?.average ?? 0)),
                                                         peak: SystemMonitorCopy.percentSpoken(MonitorFormatting.percentNumber(st?.peak ?? 0)),
                                                         window: windowLong)
                          },
                          chart: chart(id, color: .adkAccent, format: MonitorFormatting.percent),
                          extra: monitor.cpu.value.map { r in
                              AnyView(CoreStrip(cores: r.perCore, performanceCount: r.performanceCoreCount))
                          },
                          detail: monitor.cpu.value.map { r in
                              SystemMonitorCopy.cpuDetail(user: MonitorFormatting.percent(r.user), system: MonitorFormatting.percent(r.system),
                                                          cores: SystemMonitorCopy.cores(Formatting.count(ProcessInfo.processInfo.processorCount)),
                                                          peak: MonitorFormatting.percent(st?.peak ?? r.total))
                          })
    }

    private var memoryCard: some View {
        let id = SystemMonitorModel.SeriesID.memory
        let st = monitor.stats(id)
        let r = monitor.memory.value
        return MetricCard(title: SystemMonitorCopy.title(.memory),
                          value: r.map { MonitorFormatting.percent($0.usedFraction) },
                          a11yValue: r.map {
                              SystemMonitorCopy.cardA11y(value: SystemMonitorCopy.percentSpoken(MonitorFormatting.percentNumber($0.usedFraction)),
                                                         average: SystemMonitorCopy.percentSpoken(MonitorFormatting.percentNumber(st?.average ?? 0)),
                                                         peak: SystemMonitorCopy.percentSpoken(MonitorFormatting.percentNumber(st?.peak ?? 0)),
                                                         window: windowLong)
                              + ((r?.pressure).map { ", " + SystemMonitorCopy.pressureA11y(SystemMonitorCopy.pressure($0)) } ?? "")
                          },
                          badge: r?.pressure.map { AnyView(PressurePill(pressure: $0)) },
                          chart: chart(id, color: .adkKeep, format: MonitorFormatting.percent),
                          extra: r.map { m in AnyView(MemoryLegend(reading: m)) },
                          detail: r.map { m in
                              var s = SystemMonitorCopy.memoryDetail(used: Formatting.bytes(Int64(m.usedBytes)), total: Formatting.bytes(Int64(m.totalBytes)))
                              if let swap = m.swapUsedBytes { s += " · " + SystemMonitorCopy.swap(Formatting.bytes(Int64(swap))) }
                              return s
                          })
    }

    private func networkCard(_ units: NetworkUnits) -> some View {
        let down = monitor.series(.down), up = monitor.series(.up)
        let n = monitor.network.value
        let failed = monitor.network == .failed
        let peakDown = down.map(\.value).max() ?? 0, peakUp = up.map(\.value).max() ?? 0
        return MetricCard(
            title: SystemMonitorCopy.title(.network),
            value: n.map { "↓ " + MonitorFormatting.rate($0.downBytesPerSecond, units: units) + "   ↑ " + MonitorFormatting.rate($0.upBytesPerSecond, units: units) },
            a11yValue: n.map {
                SystemMonitorCopy.barDownload(SystemMonitorCopy.perSecondSpoken(MonitorFormatting.spokenAmount($0.downBytesPerSecond, units: units)))
                    + ", " + SystemMonitorCopy.barUpload(SystemMonitorCopy.perSecondSpoken(MonitorFormatting.spokenAmount($0.upBytesPerSecond, units: units)))
            },
            chart: AnyView(NetworkMirrorChart(down: down, up: up, now: monitor.currentTime, window: monitor.historyWindowSeconds)
                .accessibilityChartDescriptor(SeriesChartDescriptor(title: SystemMonitorCopy.chartTitle(SystemMonitorCopy.title(.network)),
                                                                    samples: down, now: monitor.currentTime) {
                    MonitorFormatting.rate($0, units: units)
                })),
            detail: failed ? nil : n.map { r in
                let peak = SystemMonitorCopy.networkPeak(down: MonitorFormatting.rate(peakDown, units: units),
                                                         up: MonitorFormatting.rate(peakUp, units: units))
                guard let name = r.interfaceName else { return peak }
                return SystemMonitorCopy.networkDetail(interface: [r.interfaceDisplayName, name].compactMap { $0 }.joined(separator: " · "),
                                                       down: MonitorFormatting.rate(peakDown, units: units),
                                                       up: MonitorFormatting.rate(peakUp, units: units))
            },
            error: failed ? SystemMonitorCopy.networkError : nil)
    }

    private func chart(_ id: SystemMonitorModel.SeriesID, color: Color, format: @escaping (Double) -> String) -> AnyView {
        let samples = monitor.series(id)
        return AnyView(Sparkline(samples: samples, now: monitor.currentTime, window: monitor.historyWindowSeconds, color: color)
            .accessibilityChartDescriptor(SeriesChartDescriptor(title: SystemMonitorCopy.chartTitle(SystemMonitorCopy.title(id == .cpu ? .cpu : .memory)),
                                                                samples: samples, now: monitor.currentTime, format: format)))
    }
}

struct MetricCard: View {
    let title: String
    let value: String?
    var a11yValue: String?
    var badge: AnyView?
    let chart: AnyView
    var extra: AnyView?
    let detail: String?
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let badge { badge }
                Spacer(minLength: 0)
                Text(value ?? SystemMonitorCopy.collecting)
                    .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            chart
            if let extra { extra }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.adkReviewInk).fixedSize(horizontal: false, vertical: true)
            } else if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color.adkSurface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(a11yValue ?? value ?? SystemMonitorCopy.collecting)
    }
}

/// The word is the signal; colour only supports it.
struct PressurePill: View {
    let pressure: MemoryPressure
    var body: some View {
        let (ink, soft): (Color, Color) = switch pressure {
        case .normal: (.adkSafeInk, .adkSafeSoft)
        case .warning: (.adkReviewInk, .adkReviewSoft)
        case .critical: (.adkDangerInk, .adkDangerSoft)
        }
        Text(SystemMonitorCopy.pressure(pressure))
            .font(.caption2.weight(.semibold)).foregroundStyle(ink)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(soft, in: Capsule())
    }
}

struct MemoryLegend: View {
    let reading: MemoryReading
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MemoryStrataBar(reading: reading)
            HStack(spacing: 10) {
                item(SystemMonitorCopy.memApp, reading.appBytes, .adkKeep)
                item(SystemMonitorCopy.memWired, reading.wiredBytes, StrataLayer.apps.color)
                item(SystemMonitorCopy.memCompressed, reading.compressedBytes, StrataLayer.docker.color)
            }
        }
    }
    private func item(_ label: String, _ bytes: UInt64, _ c: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(label + " " + Formatting.bytes(Int64(bytes))).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Opt-in, read-only: the user's own processes, top five by CPU or memory. The only action opens Activity Monitor.
struct TopProcessesView: View {
    let monitor: SystemMonitorModel
    @State private var byMemory = false

    var body: some View {
        @Bindable var m = monitor
        DisclosureGroup(isExpanded: $m.topProcessesExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                Picker(selection: $byMemory) {
                    Text(SystemMonitorCopy.topCPU).tag(false)
                    Text(SystemMonitorCopy.topMemory).tag(true)
                } label: { Text(SystemMonitorCopy.topProcesses) }
                .pickerStyle(.segmented).labelsHidden()
                let rows = ProcessTopN.top(monitor.processes, by: byMemory ? .memory : .cpu)
                if rows.isEmpty {
                    Text(SystemMonitorCopy.collecting).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.pid) { p in
                    HStack {
                        Text(verbatim: p.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(verbatim: byMemory ? Formatting.bytes(Int64(p.memoryBytes)) : "\(Int(p.cpuPercent.rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
                HStack {
                    Text(SystemMonitorCopy.topOwnOnly).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(SystemMonitorCopy.openActivityMonitor) { Self.openActivityMonitor() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(SystemMonitorCopy.topProcesses).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
