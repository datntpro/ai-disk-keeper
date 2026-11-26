import Foundation

/// One sampler result: a value, "need one more sample" (rates need a delta) or a read failure.
public enum SampleResult<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    case pending
    case failed

    public var value: Value? { if case .value(let v) = self { v } else { nil } }
}

public struct CPUReading: Sendable, Equatable {
    /// 0…1 over all cores.
    public var total: Double
    public var user: Double
    public var system: Double
    /// Per logical core (popover only).
    public var perCore: [Double]
    public var performanceCoreCount: Int?
    public init(total: Double, user: Double, system: Double, perCore: [Double] = [], performanceCoreCount: Int? = nil) {
        self.total = total; self.user = user; self.system = system
        self.perCore = perCore; self.performanceCoreCount = performanceCoreCount
    }
}

public enum MemoryPressure: Int, Sendable, Equatable {
    case normal = 1, warning = 2, critical = 4
}

public struct MemoryReading: Sendable, Equatable {
    public var totalBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var swapUsedBytes: UInt64?
    public var pressure: MemoryPressure?
    public var usedBytes: UInt64 { appBytes &+ wiredBytes &+ compressedBytes }
    /// 0…1.
    public var usedFraction: Double { totalBytes == 0 ? 0 : min(1, max(0, Double(usedBytes) / Double(totalBytes))) }
    public init(totalBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
                swapUsedBytes: UInt64? = nil, pressure: MemoryPressure? = nil) {
        self.totalBytes = totalBytes; self.appBytes = appBytes; self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes; self.swapUsedBytes = swapUsedBytes; self.pressure = pressure
    }
}

public struct NetworkReading: Sendable, Equatable {
    /// Bytes per second.
    public var downBytesPerSecond: Double
    public var upBytesPerSecond: Double
    /// Busiest interface: BSD name and its localized display name ("Wi-Fi").
    public var interfaceName: String?
    public var interfaceDisplayName: String?
    public init(down: Double, up: Double, interfaceName: String? = nil, interfaceDisplayName: String? = nil) {
        self.downBytesPerSecond = down; self.upBytesPerSecond = up
        self.interfaceName = interfaceName; self.interfaceDisplayName = interfaceDisplayName
    }
}

/// Own-user process usage (read-only).
public struct ProcessUsage: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// Percent of one core (100 = one full core).
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid; self.name = name; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }
}

/// Everything one tick measured. Fields are nil when that sampler did not run this tick.
public struct SystemSnapshot: Sendable, Equatable {
    public var cpu: SampleResult<CPUReading>?
    public var memory: SampleResult<MemoryReading>?
    public var network: SampleResult<NetworkReading>?
    public var processes: [ProcessUsage]?
    public init(cpu: SampleResult<CPUReading>? = nil, memory: SampleResult<MemoryReading>? = nil,
                network: SampleResult<NetworkReading>? = nil, processes: [ProcessUsage]? = nil) {
        self.cpu = cpu; self.memory = memory; self.network = network; self.processes = processes
    }
}
