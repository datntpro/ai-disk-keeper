import Foundation
import IOKit

/// Cumulative counters of an `IOBlockStorageDriver` since boot.
public struct DiskStatistics: Sendable, Equatable {
    public let bytesRead: UInt64, bytesWritten: UInt64
    /// Total time spent on requests (queue time, summed over parallel requests), nanoseconds.
    public let totalTimeReadNs: UInt64, totalTimeWriteNs: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64, totalTimeReadNs: UInt64, totalTimeWriteNs: UInt64) {
        self.bytesRead = bytesRead; self.bytesWritten = bytesWritten
        self.totalTimeReadNs = totalTimeReadNs; self.totalTimeWriteNs = totalTimeWriteNs
    }

    /// Parses the registry's `Statistics` dictionary. Pure, so a recorded dictionary tests it. Any missing key → nil.
    public init?(dictionary d: [String: Any]) {
        func value(_ key: String) -> UInt64? { (d[key] as? NSNumber)?.uint64Value }
        guard let r = value("Bytes (Read)"), let w = value("Bytes (Write)"),
              let tr = value("Total Time (Read)"), let tw = value("Total Time (Write)") else { return nil }
        self.init(bytesRead: r, bytesWritten: w, totalTimeReadNs: tr, totalTimeWriteNs: tw)
    }
}

public protocol DiskStatisticsReading: Sendable {
    func read() -> DiskStatistics?
}

/// Whole-disk throughput over one tick.
public struct DiskActivity: Sendable, Equatable {
    public let readBytesPerSec: Double, writeBytesPerSec: Double
    /// Approximate: Δ(read + write request time) / Δt, clamped to 0…1. It is queue time, not active time.
    public let busyFraction: Double
}

/// Rates from deltas of `DiskStatistics`. A counter that went down (reset) gives no rate for that tick.
public struct DiskActivityTracker: Sendable {
    private var previous: (stats: DiskStatistics, at: ContinuousClock.Instant)?

    public init() {}

    public mutating func update(_ stats: DiskStatistics, at: ContinuousClock.Instant) -> DiskActivity? {
        defer { previous = (stats, at) }
        guard let p = previous else { return nil }
        let d = at - p.at
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        guard seconds > 0, seconds <= IORateTracker.maximumGap, stats.bytesRead >= p.stats.bytesRead, stats.bytesWritten >= p.stats.bytesWritten,
              stats.totalTimeReadNs >= p.stats.totalTimeReadNs, stats.totalTimeWriteNs >= p.stats.totalTimeWriteNs else { return nil }
        let busyNs = Double(stats.totalTimeReadNs - p.stats.totalTimeReadNs) + Double(stats.totalTimeWriteNs - p.stats.totalTimeWriteNs)
        return DiskActivity(readBytesPerSec: Double(stats.bytesRead - p.stats.bytesRead) / seconds,
                            writeBytesPerSec: Double(stats.bytesWritten - p.stats.bytesWritten) / seconds,
                            busyFraction: min(1, max(0, busyNs / (seconds * 1e9))))
    }
}

/// IOKit, no subprocess. Reads the internal block storage driver with the most traffic (the boot SSD on a laptop);
/// external and USB drives are skipped.
public struct LiveDiskStatisticsReader: DiskStatisticsReading {
    public init() {}

    public func read() -> DiskStatistics? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: DiskStatistics?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard Self.isInternal(entry),
                  let raw = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let dict = raw as? [String: Any], let stats = DiskStatistics(dictionary: dict) else { continue }
            if best == nil || stats.bytesRead &+ stats.bytesWritten > best!.bytesRead &+ best!.bytesWritten { best = stats }
        }
        return best
    }

    private static func isInternal(_ entry: io_registry_entry_t) -> Bool {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let raw = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "Protocol Characteristics" as CFString,
                                                        kCFAllocatorDefault, options),
              let dict = raw as? [String: Any] else { return false }
        return (dict["Physical Interconnect Location"] as? String) == "Internal"
    }
}
