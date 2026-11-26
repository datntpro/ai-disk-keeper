import Darwin
import Foundation

public enum ProcessTopN {
    public enum Column: Sendable { case cpu, memory }

    /// Descending by the column; ties by name, then pid, so the order is stable.
    public static func top(_ items: [ProcessUsage], by column: Column, limit: Int = 5) -> [ProcessUsage] {
        items.sorted {
            let (a, b) = column == .cpu ? ($0.cpuPercent, $1.cpuPercent) : (Double($0.memoryBytes), Double($1.memoryBytes))
            if a != b { return a > b }
            return $0.name != $1.name ? $0.name < $1.name : $0.pid < $1.pid
        }.prefix(limit).map { $0 }
    }
}

/// Own-user processes only (others fail with EPERM and are skipped). Read-only; no path lookups.
public struct LiveProcessUsageSampler: ProcessSampling {
    private var previousTime: [Int32: UInt64] = [:]
    private var previousAt: ContinuousClock.Instant?
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(max(t.denom, 1)))
    }()

    public init() {}

    /// All visible processes; the caller picks the top N by column.
    public mutating func sample() -> [ProcessUsage] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 16)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        let now = ContinuousClock.now
        let elapsedNs: Double? = previousAt.map { let d = now - $0; return (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1e9 }
        var times: [Int32: UInt64] = [:]
        var out: [ProcessUsage] = []
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } == 0
            }
            guard ok else { continue }   // EPERM (other users) or vanished
            let ticks = info.ri_user_time &+ info.ri_system_time
            times[pid] = ticks
            var cpu = 0.0
            if let prev = previousTime[pid], let elapsedNs, elapsedNs > 0, ticks >= prev {
                let ns = Double((ticks - prev) &* Self.timebase.numer / Self.timebase.denom)
                cpu = ns / elapsedNs * 100
            }
            out.append(ProcessUsage(pid: pid, name: Self.name(pid), cpuPercent: cpu, memoryBytes: info.ri_phys_footprint))
        }
        previousTime = times   // trimmed to live pids
        previousAt = now
        return out
    }

    private static func name(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
    }
}
