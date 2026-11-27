import Darwin
import Foundation

/// Page counts from `vm_statistics64`, as recorded (tests feed fixtures).
public struct VMCounts: Sendable, Equatable {
    public var internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressorPages: UInt64
    public init(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressorPages: UInt64) {
        self.internalPages = internalPages; self.purgeablePages = purgeablePages
        self.wiredPages = wiredPages; self.compressorPages = compressorPages
    }
}

public enum MemoryMath {
    /// App = internal − purgeable, Wired = wired, Compressed = compressor pages. Used % = their sum over total.
    public static func reading(_ v: VMCounts, pageSize: UInt64, totalBytes: UInt64, swapUsed: UInt64?,
                               pressure: MemoryPressure?) -> MemoryReading {
        let app = (v.internalPages > v.purgeablePages ? v.internalPages - v.purgeablePages : 0) &* pageSize
        return MemoryReading(totalBytes: totalBytes, appBytes: app, wiredBytes: v.wiredPages &* pageSize,
                             compressedBytes: v.compressorPages &* pageSize, swapUsedBytes: swapUsed, pressure: pressure)
    }

    public static func pressure(sysctlLevel: Int32) -> MemoryPressure? { MemoryPressure(rawValue: Int(sysctlLevel)) }
}

public struct LiveMemorySampler: MemorySampling {
    private static let host: mach_port_t = mach_host_self()
    public init() {}

    public mutating func sample() -> SampleResult<MemoryReading> {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(Self.host, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return .failed }
        let v = VMCounts(internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
                         wiredPages: UInt64(stats.wire_count), compressorPages: UInt64(stats.compressor_page_count))
        return .value(MemoryMath.reading(v, pageSize: UInt64(sysconf(_SC_PAGESIZE)), totalBytes: ProcessInfo.processInfo.physicalMemory,
                                         swapUsed: Self.swapUsed(), pressure: Self.pressure()))
    }

    private static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : nil
    }

    /// `kern.memorystatus_vm_pressure_level` (no subprocess, no root); nil when the sysctl is unavailable.
    public static func pressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return MemoryMath.pressure(sysctlLevel: level)
    }
}
