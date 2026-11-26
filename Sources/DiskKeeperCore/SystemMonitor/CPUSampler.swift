import Darwin
import Foundation

public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

/// Pure tick math. Deltas use wrapping subtraction because the kernel counters are `natural_t` (UInt32).
public enum CPULoadMath {
    public struct Usage: Equatable, Sendable { public var total: Double, user: Double, system: Double }

    /// nil when no time passed (zero delta): the caller keeps the previous reading.
    public static func usage(from a: CPUTicks, to b: CPUTicks) -> Usage? {
        let du = Double(b.user &- a.user), ds = Double(b.system &- a.system)
        let di = Double(b.idle &- a.idle), dn = Double(b.nice &- a.nice)
        let all = du + ds + di + dn
        guard all > 0 else { return nil }
        return Usage(total: (du + ds + dn) / all, user: (du + dn) / all, system: ds / all)
    }
}

public struct LiveCPUSampler: CPUSampling {
    /// One send right for the process lifetime; `mach_host_self()` per tick would leak rights.
    private static let host: mach_port_t = mach_host_self()
    private static let performanceCores: Int? = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel0.logicalcpu", &n, &size, nil, 0) == 0 && n > 0 ? Int(n) : nil
    }()

    private var previousTotal: CPUTicks?
    private var previousCores: [CPUTicks] = []
    private var last: CPUReading?

    public init() {}

    public mutating func sample(perCore: Bool) -> SampleResult<CPUReading> {
        guard let now = Self.readTotal() else { return .failed }
        defer { previousTotal = now }
        let cores = perCore ? Self.readCores() : nil
        defer { if let cores { previousCores = cores } }
        guard let before = previousTotal else { return .pending }
        guard let u = CPULoadMath.usage(from: before, to: now) else {
            return last.map { .value($0) } ?? .pending
        }
        var perCoreUsage: [Double] = []
        if let cores, cores.count == previousCores.count {
            perCoreUsage = zip(previousCores, cores).map { CPULoadMath.usage(from: $0, to: $1)?.total ?? 0 }
        }
        let r = CPUReading(total: u.total, user: u.user, system: u.system, perCore: perCoreUsage,
                           performanceCoreCount: Self.performanceCores)
        last = r
        return .value(r)
    }

    private static func readTotal() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private static func readCores() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var infoPtr: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoPtr, &infoCount) == KERN_SUCCESS, let infoPtr else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: infoPtr)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size)) }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { i in
            let b = i * stride
            return CPUTicks(user: UInt32(bitPattern: infoPtr[b + Int(CPU_STATE_USER)]),
                            system: UInt32(bitPattern: infoPtr[b + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt32(bitPattern: infoPtr[b + Int(CPU_STATE_IDLE)]),
                            nice: UInt32(bitPattern: infoPtr[b + Int(CPU_STATE_NICE)]))
        }
    }
}
