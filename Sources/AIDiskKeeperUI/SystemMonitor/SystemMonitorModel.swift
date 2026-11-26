import AppKit
import DiskKeeperCore
import Foundation
import Observation

/// What the popover and the menu bar label show: the latest readings, in-memory histories and the rendered label.
/// It never samples by itself; the scheduler hands it one snapshot per tick.
@MainActor @Observable
final class SystemMonitorModel {
    enum SeriesID: Hashable { case cpu, memory, down, up }

    private(set) var cpu: SampleResult<CPUReading> = .pending
    private(set) var memory: SampleResult<MemoryReading> = .pending
    private(set) var network: SampleResult<NetworkReading> = .pending
    private(set) var processes: [ProcessUsage] = []
    private(set) var histories: [SeriesID: MetricHistory] = [:]
    private(set) var labelImage: NSImage
    private(set) var labelAccessibility: String = ""
    private(set) var popoverOpen = false
    var topProcessesExpanded = false { didSet { if oldValue != topProcessesExpanded { demandChanged() } } }

    let settings: SettingsModel
    let menuBar: MenuBarModel

    @ObservationIgnored var onDemandChange: (() -> Void)?
    @ObservationIgnored private(set) var displayAsleep = false
    @ObservationIgnored private(set) var systemAsleep = false
    @ObservationIgnored weak var popoverWindow: NSWindow?
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let renderLabel: (LabelContent) -> NSImage
    @ObservationIgnored private let measure: (String) -> CGFloat
    @ObservationIgnored private let measureDisk: (String) -> CGFloat
    @ObservationIgnored private var lastContent: LabelContent?

    static let defaultClock: () -> Double = {
        let base = ContinuousClock.now
        return { let d = ContinuousClock.now - base; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    }()

    init(settings: SettingsModel, menuBar: MenuBarModel, now: @escaping () -> Double = SystemMonitorModel.defaultClock,
         measure: ((String) -> CGFloat)? = nil, measureDisk: ((String) -> CGFloat)? = nil,
         renderLabel: @escaping (LabelContent) -> NSImage = MenuBarLabelRenderer.render) {
        self.settings = settings
        self.menuBar = menuBar
        self.now = now
        // Injected measures (tests) drive the disk cell too; production measures it in the T47 menu bar font.
        self.measure = measure ?? MenuBarLayout.measureText
        self.measureDisk = measureDisk ?? (measure == nil ? MenuBarLayout.measureDiskText : self.measure)
        self.renderLabel = renderLabel
        self.labelImage = StrataGlyph.image()
        refreshLabel()
    }

    // MARK: Demand

    var demand: Demand {
        let s = settings.settings
        var d = Demand()
        d.popoverOpen = popoverOpen
        d.barMetrics = Set(drawnBarMetrics)
        d.enabledMetrics = Set(s.enabledMetricsInOrder)
        d.topProcessesVisible = s.popoverShowsTopProcesses && topProcessesExpanded
        d.itemInserted = s.showMenuBarItem
        d.displayAsleep = displayAsleep
        d.systemAsleep = systemAsleep
        d.barInterval = .seconds(SamplingPolicy.snapBarSeconds(s.menuBarRefreshSeconds))
        return d
    }

    /// The metrics the chosen style actually draws: Glyph draws none, Live strata three meters (disk counts toward
    /// the three), the others every metric in the bar. Anything not drawn is neither sampled nor spoken.
    var drawnBarMetrics: [MetricID] {
        let s = settings.settings
        switch s.menuBarStyle {
        case .glyph: return []
        case .liveStrata: return Array(s.menuBarMetricsInOrder.prefix(3)).filter { $0 != .disk }
        case .readout, .ridge: return s.menuBarMetricsInOrder.filter { $0 != .disk }
        }
    }

    func setPopoverOpen(_ open: Bool) {
        guard popoverOpen != open else { return }
        popoverOpen = open
        if !open { topProcessesExpanded = false }
        demandChanged()
    }
    func setDisplayAsleep(_ v: Bool) { guard displayAsleep != v else { return }; displayAsleep = v; demandChanged() }
    func setSystemAsleep(_ v: Bool) { guard systemAsleep != v else { return }; systemAsleep = v; demandChanged() }
    func demandChanged() { onDemandChange?() }

    // MARK: Apply

    /// One observable mutation batch per tick.
    func apply(_ snapshot: SystemSnapshot) {
        let t = now()
        // Observation fires on every set, so only assign what changed: an unchanged value must not re-lay out a view.
        if let c = snapshot.cpu {
            if c != .pending, c != cpu { cpu = c }
            if let v = c.value { append(.cpu, t, v.total) }
        }
        if let m = snapshot.memory {
            if m != memory { memory = m }
            if let v = m.value { append(.memory, t, v.usedFraction) }
        }
        if let n = snapshot.network {
            if n != .pending, n != network { network = n }
            if let v = n.value { append(.down, t, v.downBytesPerSecond); append(.up, t, v.upBytesPerSecond) }
        }
        if let p = snapshot.processes, p != processes { processes = p }
        refreshLabel()
    }

    private func append(_ id: SeriesID, _ t: Double, _ v: Double) {
        histories[id, default: MetricHistory()].append(time: t, value: v)
    }

    /// Resets what a sleep or a long pause makes stale.
    func markStale() {
        if case .value = cpu { cpu = .pending }
        if case .value = network { network = .pending }
    }

    // MARK: Label

    func labelEntries() -> [MenuBarLayout.Entry] {
        let s = settings.settings
        let units = s.networkUnits
        return s.menuBarMetricsInOrder.map { m in
            switch m {
            case .disk:
                return .init(metric: .disk, text: menuBar.freeBytes.map { Formatting.bytes($0) } ?? "—")
            case .cpu:
                return .init(metric: .cpu, text: cpu.value.map { MonitorFormatting.percent($0.total) } ?? "–")
            case .memory:
                return .init(metric: .memory, text: memory.value.map { MonitorFormatting.percent($0.usedFraction) } ?? "–")
            case .network:
                guard let n = network.value else { return .init(metric: .network, text: "↓–", up: "↑–") }
                return .init(metric: .network, text: "↓" + MonitorFormatting.compactRate(n.downBytesPerSecond, units: units),
                             up: "↑" + MonitorFormatting.compactRate(n.upBytesPerSecond, units: units),
                             upIsNegligible: n.upBytesPerSecond < 1000)
            }
        }
    }

    func makeContent() -> LabelContent {
        let s = settings.settings
        let layout = MenuBarLayout.layout(style: s.menuBarStyle, entries: labelEntries(), measure: measure, measureDisk: measureDisk)
        var c = LabelContent(layout: layout)
        let inBar = s.menuBarMetricsInOrder
        let q = LabelContent.quantize
        if layout.cells.contains(where: { $0.showsRidge }) {
            for m in [MetricID.cpu, .memory] where inBar.contains(m) {
                c.ridges[m] = tail(m == .cpu ? .cpu : .memory).map { q($0) }
            }
            if inBar.contains(.network) {
                let down = tail(.down), up = tail(.up)
                let peak = max(100_000, down.max() ?? 0, up.max() ?? 0)
                c.ridges[.network] = down.map { q($0 / peak) }
                c.ridgeUp = up.map { q($0 / peak) }
            }
        }
        if layout.mode == .strata {
            c.meters = inBar.prefix(3).map { q(meter($0)) }
        }
        if layout.mode == .readout, case .value(let m) = memory, let p = m.pressure, p != .normal { c.pressureDot = true }
        return c
    }

    private func tail(_ id: SeriesID, count: Int = 24) -> [Double] {
        (histories[id]?.samples ?? []).suffix(count).map(\.value)
    }

    private func meter(_ m: MetricID) -> Double {
        switch m {
        case .disk: return menuBar.freeFraction ?? 0
        case .cpu: return cpu.value?.total ?? 0
        case .memory: return memory.value?.usedFraction ?? 0
        case .network:
            guard let n = network.value else { return 0 }
            let peak = max(100_000, (histories[.down]?.samples.map(\.value).max() ?? 0), (histories[.up]?.samples.map(\.value).max() ?? 0))
            return max(n.downBytesPerSecond, n.upBytesPerSecond) / peak
        }
    }

    /// Re-renders only when the visible content changed; otherwise publishes nothing.
    func refreshLabel() {
        let content = makeContent()
        let a11y = makeAccessibility()
        if a11y != labelAccessibility { labelAccessibility = a11y }
        guard content != lastContent else { return }
        lastContent = content
        labelImage = renderLabel(content)
    }

    func makeAccessibility() -> String {
        let s = settings.settings
        let units = s.networkUnits
        var parts: [String] = []
        for m in drawnBarMetrics {
            switch m {
            case .cpu: parts.append(SystemMonitorCopy.barCPU(SystemMonitorCopy.percentSpoken(cpu.value.map { MonitorFormatting.percentNumber($0.total) } ?? "—")))
            case .memory: parts.append(SystemMonitorCopy.barMemory(SystemMonitorCopy.percentSpoken(memory.value.map { MonitorFormatting.percentNumber($0.usedFraction) } ?? "—")))
            case .network:
                if let n = network.value {
                    parts.append(SystemMonitorCopy.barDownload(SystemMonitorCopy.perSecondSpoken(MonitorFormatting.spokenAmount(n.downBytesPerSecond, units: units))))
                    parts.append(SystemMonitorCopy.barUpload(SystemMonitorCopy.perSecondSpoken(MonitorFormatting.spokenAmount(n.upBytesPerSecond, units: units))))
                }
            case .disk: break
            }
        }
        let base = s.menuBarShowsFreeSpace ? menuBar.labelAccessibility : StrataGlyph.accessibilityDescription
        return parts.isEmpty ? base : SystemMonitorCopy.barJoin(base, parts.joined(separator: ", "))
    }

    // MARK: History for the popover

    var historyWindowSeconds: Double { Double(settings.settings.popoverHistoryMinutes) * 60 }

    func series(_ id: SeriesID) -> [MetricHistory.Sample] { histories[id]?.window(historyWindowSeconds, now: now()) ?? [] }
    var currentTime: Double { now() }

    struct Stats: Equatable { var average: Double; var peak: Double }
    func stats(_ id: SeriesID) -> Stats? {
        let v = series(id).map(\.value)
        guard !v.isEmpty else { return nil }
        return Stats(average: v.reduce(0, +) / Double(v.count), peak: v.max() ?? 0)
    }
}
