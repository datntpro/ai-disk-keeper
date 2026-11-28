import Foundation

/// What the policy needs from one 30 s sample. Plain values so the rules are a table in tests.
public struct HostStatusSample: Sendable, Equatable {
    public var freeBytes: Int64?, totalBytes: Int64?
    public var timeToFullHours: Double?
    public var writeBytesPerSec: Double?
    public var loadAverage1: Double
    public var cpuCount: Int
    public var memoryPressure: MemoryPressure?

    public init(freeBytes: Int64? = nil, totalBytes: Int64? = nil, timeToFullHours: Double? = nil, writeBytesPerSec: Double? = nil,
                loadAverage1: Double = 0, cpuCount: Int = 1, memoryPressure: MemoryPressure? = nil) {
        self.freeBytes = freeBytes; self.totalBytes = totalBytes; self.timeToFullHours = timeToFullHours
        self.writeBytesPerSec = writeBytesPerSec; self.loadAverage1 = loadAverage1; self.cpuCount = cpuCount; self.memoryPressure = memoryPressure
    }

    var freeFraction: Double? {
        guard let free = freeBytes, let total = totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(free) / Double(total)))
    }
    var highWrites: Bool { (writeBytesPerSec ?? 0) > HostStatusPolicy.writeBytesPerSecLimit }
    var highLoad: Bool { loadAverage1 > HostStatusPolicy.loadFactor * Double(max(1, cpuCount)) }
}

/// Levels (D10). "Sustained" = true in this sample and the one before it.
public enum HostStatusPolicy {
    public static let writeBytesPerSecLimit = 200_000_000.0
    public static let loadFactor = 0.8
    public static let criticalHours = 6.0
    public static let warnHours = 48.0

    public static func evaluate(_ now: HostStatusSample, previous: HostStatusSample?, thresholdPercent: Int)
        -> (level: HostStatusLevel, reasons: [HostStatus.Reason]) {
        var level = HostStatusLevel.ok
        var reasons: [HostStatus.Reason] = []
        func add(_ l: HostStatusLevel, _ code: HostStatusReasonCode, _ message: String) {
            level = max(level, l)
            reasons.append(.init(code: code, message: message))
        }

        if let fraction = now.freeFraction, let free = now.freeBytes {
            let percent = Self.percent(fraction)
            if fraction < FreeSpaceStatus.criticalFraction || free < FreeSpaceStatus.criticalBytes {
                add(.critical, .lowFreeSpace, "Free space \(percent)% (critical: < 5% or < 10 GB)")
            } else if fraction < Double(thresholdPercent) / 100 {
                add(.warn, .lowFreeSpace, "Free space \(percent)% (< \(thresholdPercent)%)")
            }
        }
        if let hours = now.timeToFullHours {
            if hours < criticalHours { add(.critical, .fullSoon, "Disk full in about \(Self.hours(hours))") }
            else if hours < warnHours { add(.warn, .fullSoon, "Disk full in about \(Self.hours(hours))") }
        }
        if now.highWrites, previous?.highWrites == true, let w = now.writeBytesPerSec {
            add(.warn, .highDiskWrites, "Disk writes \(Int(w / 1_000_000)) MB/s (sustained, > 200 MB/s)")
        }
        if now.highLoad, previous?.highLoad == true {
            add(.warn, .highLoad, "Load average \(String(format: "%.1f", now.loadAverage1)) on \(now.cpuCount) cores (sustained, > 80%)")
        }
        if let p = now.memoryPressure, p != .normal {
            add(.warn, .memoryPressure, "Memory pressure: \(p == .critical ? "critical" : "warning")")
        }
        return (level, reasons)
    }

    private static func percent(_ f: Double) -> String { String(Int((f * 100).rounded())) }
    private static func hours(_ h: Double) -> String { h < 1 ? "<1 h" : "\(Int(h.rounded())) h" }
}

/// Turns each host-load tick into a `HostStatus`, remembering the previous sample for "sustained".
public struct HostStatusComposer: Sendable {
    public let volume: String
    public let version: String
    public let pid: Int32
    public let intervalSeconds: Int
    private var previous: HostStatusSample?

    public init(volume: String = DataVolume.path, version: String, pid: Int32 = getpid(), intervalSeconds: Int = 30) {
        self.volume = volume; self.version = version; self.pid = pid; self.intervalSeconds = intervalSeconds
    }

    public mutating func compose(_ snap: HostLoadSnapshot, thresholdPercent: Int, sampleSeconds: Double, now: Date = Date()) -> HostStatus {
        let free = snap.freeSpace
        let sample = HostStatusSample(
            freeBytes: free?.freeBytes, totalBytes: free?.totalBytes, timeToFullHours: free?.trend?.timeToFull.map { $0 / 3600 },
            writeBytesPerSec: snap.disk?.writeBytesPerSec, loadAverage1: snap.loadAverage.0, cpuCount: snap.cpuCount,
            memoryPressure: snap.memoryPressure)
        let (level, reasons) = HostStatusPolicy.evaluate(sample, previous: previous, thresholdPercent: thresholdPercent)
        previous = sample
        return HostStatus(
            generatedAt: now, intervalSeconds: intervalSeconds, running: true, generator: .init(version: version, pid: pid),
            level: level, reasons: reasons,
            disk: free.map { .init(volume: volume, totalBytes: $0.totalBytes, freeBytes: $0.freeBytes, freePercent: ($0.freeFraction * 1000).rounded() / 10,
                                   thresholdPercent: thresholdPercent, trendBytesPerHour: $0.trend?.bytesPerHour,
                                   timeToFullHours: $0.trend?.timeToFull.map { $0 / 3600 }) },
            io: snap.disk.map { .init(readBytesPerSec: $0.readBytesPerSec, writeBytesPerSec: $0.writeBytesPerSec,
                                      busyPercent: ($0.busyFraction * 1000).rounded() / 10, sampleSeconds: sampleSeconds) },
            load: .init(loadAverage1: snap.loadAverage.0, cpuCount: snap.cpuCount, memoryPressure: snap.memoryPressure.map(Self.pressureName)),
            topWriters: snap.processes.filter { $0.writeBytesPerSec > 0 }.prefix(HostStatus.maxTopWriters).map {
                .init(pid: $0.pid, name: $0.name, agent: $0.agent?.rawValue, worktree: $0.worktree?.root, writeBytesPerSec: $0.writeBytesPerSec)
            },
            worktrees: snap.byWorktree.prefix(HostStatus.maxWorktrees).map {
                .init(path: $0.worktree.root, repo: $0.worktree.repoRoot, writeBytesPerSec: $0.writeBytesPerSec,
                      processCount: $0.processCount, agents: $0.agents.map(\.rawValue))
            })
    }

    private static func pressureName(_ p: MemoryPressure) -> String {
        switch p { case .normal: "normal"; case .warning: "warning"; case .critical: "critical" }
    }
}
