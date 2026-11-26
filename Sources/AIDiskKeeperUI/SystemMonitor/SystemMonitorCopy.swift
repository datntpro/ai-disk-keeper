import DiskKeeperCore
import Foundation

/// Every string of the system monitor (popover, menu bar accessibility, Settings). Numbers arrive already formatted;
/// units (GB, KB/s, %) are never translated.
enum SystemMonitorCopy {
    static var section: String { loc("sysmon.section", "System") }
    static func every(_ seconds: String) -> String { loc("sysmon.every", "every \(seconds) s") }
    static var window1: String { loc("sysmon.window.1", "1 min") }
    static var window5: String { loc("sysmon.window.5", "5 min") }
    static var window1Long: String { loc("sysmon.window.1.long", "1 minute") }
    static var window5Long: String { loc("sysmon.window.5.long", "5 minutes") }
    static var collecting: String { loc("sysmon.collecting", "Collecting…") }

    static func title(_ m: MetricID) -> String {
        switch m {
        case .disk: loc("sysmon.disk", "Disk")
        case .cpu: loc("sysmon.cpu", "CPU")
        case .memory: loc("sysmon.memory", "Memory")
        case .network: loc("sysmon.network", "Network")
        }
    }

    static func cpuDetail(user: String, system: String, cores: String, peak: String) -> String {
        loc("sysmon.cpu.detail", "User \(user) · System \(system) · \(cores) · peak \(peak)")
    }
    static func cores(_ n: String) -> String { loc("sysmon.cpu.cores", "\(n) cores") }
    static func memoryDetail(used: String, total: String) -> String { loc("sysmon.mem.detail", "\(used) of \(total)") }
    static func swap(_ bytes: String) -> String { loc("sysmon.mem.swap", "Swap \(bytes)") }
    static var memApp: String { loc("sysmon.mem.app", "App") }
    static var memWired: String { loc("sysmon.mem.wired", "Wired") }
    static var memCompressed: String { loc("sysmon.mem.compressed", "Compressed") }

    static func pressure(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: loc("sysmon.pressure.normal", "Normal")
        case .warning: loc("sysmon.pressure.warning", "Warning")
        case .critical: loc("sysmon.pressure.critical", "Critical")
        }
    }
    static func pressureA11y(_ p: String) -> String { loc("sysmon.pressure.a11y", "Memory pressure \(p)") }

    static var download: String { loc("sysmon.net.down", "Download") }
    static var upload: String { loc("sysmon.net.up", "Upload") }
    static func networkDetail(interface: String, down: String, up: String) -> String {
        loc("sysmon.net.detail", "\(interface) · peak ↓ \(down) ↑ \(up)")
    }
    static func networkPeak(down: String, up: String) -> String { loc("sysmon.net.peak", "peak ↓ \(down) ↑ \(up)") }
    static var networkError: String { loc("sysmon.net.error", "Couldn't read network counters. Nothing was changed.") }

    static var topProcesses: String { loc("sysmon.top.title", "Top processes") }
    static var topOwnOnly: String { loc("sysmon.top.own", "Your processes only") }
    static var topCPU: String { loc("sysmon.top.cpu", "CPU") }
    static var topMemory: String { loc("sysmon.top.memory", "Memory") }
    static var openActivityMonitor: String { loc("sysmon.top.open", "Activity Monitor ↗") }

    // Spoken forms (VoiceOver): words, not symbols.
    static func percentSpoken(_ n: String) -> String { loc("sysmon.a11y.percent", "\(n) percent") }
    static func perSecondSpoken(_ amount: String) -> String { loc("sysmon.a11y.perSecond", "\(amount) per second") }
    static func barCPU(_ percent: String) -> String { loc("sysmon.a11y.bar.cpu", "CPU \(percent)") }
    static func barMemory(_ percent: String) -> String { loc("sysmon.a11y.bar.memory", "memory \(percent)") }
    static func barDownload(_ rate: String) -> String { loc("sysmon.a11y.bar.down", "download \(rate)") }
    static func barUpload(_ rate: String) -> String { loc("sysmon.a11y.bar.up", "upload \(rate)") }
    static func barJoin(_ base: String, _ parts: String) -> String { loc("sysmon.a11y.bar.join", "\(base), \(parts)") }
    static func cardA11y(value: String, average: String, peak: String, window: String) -> String {
        loc("sysmon.a11y.card", "\(value), average \(average), peak \(peak) over \(window)")
    }
    static func chartTitle(_ metric: String) -> String { loc("sysmon.chart.title", "\(metric) over time") }
    static var chartSeconds: String { loc("sysmon.chart.seconds", "Seconds ago") }

    // Settings
    static var style: String { loc("settings.sysmon.style", "Menu bar style") }
    static func styleName(_ s: MenuBarStyle) -> String {
        switch s {
        case .glyph: loc("settings.sysmon.style.glyph", "Glyph")
        case .readout: loc("settings.sysmon.style.readout", "Readout")
        case .ridge: loc("settings.sysmon.style.ridge", "Ridge")
        case .liveStrata: loc("settings.sysmon.style.liveStrata", "Live strata")
        }
    }
    static var styleNote: String {
        loc("settings.sysmon.style.note", "Glyph shows only the icon (and free space). The other styles add the metrics you put in the menu bar.")
    }
    static var metrics: String { loc("settings.sysmon.metrics", "Metrics") }
    static var monitor: String { loc("settings.sysmon.monitor", "Monitor") }
    static var inMenuBar: String { loc("settings.sysmon.inBar", "In menu bar") }
    static var diskAlways: String { loc("settings.sysmon.diskAlways", "Disk is always monitored for the low-space alert.") }
    static var moveUp: String { loc("settings.sysmon.moveUp", "Move up") }
    static var moveDown: String { loc("settings.sysmon.moveDown", "Move down") }
    static var refresh: String { loc("settings.sysmon.refresh", "Menu bar refresh") }
    static func refreshEvery(_ n: String) -> String { loc("settings.sysmon.refresh.every", "Every \(n) seconds") }
    static var units: String { loc("settings.sysmon.units", "Network units") }
    static var unitsBytes: String { loc("settings.sysmon.units.bytes", "Bytes per second (MB/s)") }
    static var unitsBits: String { loc("settings.sysmon.units.bits", "Bits per second (Mb/s)") }
    static var topProcessesToggle: String { loc("settings.sysmon.topProcesses", "Show top processes in the popover") }
    static var topProcessesNote: String {
        loc("settings.sysmon.topProcesses.note", "Your own processes only. Read-only: nothing can be quit from here.")
    }
    static var needsItem: String { loc("settings.sysmon.needsItem", "Turn on Show in menu bar to use the monitor.") }
    static func widthPreview(_ pt: String, _ budget: String) -> String {
        loc("settings.sysmon.width", "Menu bar width: \(pt) pt of \(budget) pt")
    }
    static var steppedDown: String {
        loc("settings.sysmon.stepped", "Too wide for the menu bar: the item shows a shorter form automatically.")
    }
    static var monitorGroup: String { loc("settings.sysmon.group", "System monitor") }
}
