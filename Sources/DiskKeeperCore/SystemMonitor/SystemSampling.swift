import Foundation

public protocol CPUSampling: Sendable { mutating func sample(perCore: Bool) -> SampleResult<CPUReading> }
public protocol MemorySampling: Sendable { mutating func sample() -> SampleResult<MemoryReading> }
public protocol NetworkSampling: Sendable { mutating func sample() -> SampleResult<NetworkReading> }
public protocol ProcessSampling: Sendable { mutating func sample() -> [ProcessUsage] }

/// Owns the samplers and runs only the ones a tick asks for, off the main actor. One call = one snapshot.
public actor SystemSampler {
    private var cpu: any CPUSampling
    private var memory: any MemorySampling
    private var network: any NetworkSampling
    private var processes: any ProcessSampling

    public init(cpu: any CPUSampling = LiveCPUSampler(), memory: any MemorySampling = LiveMemorySampler(),
                network: any NetworkSampling = LiveNetworkSampler(), processes: any ProcessSampling = LiveProcessUsageSampler()) {
        self.cpu = cpu; self.memory = memory; self.network = network; self.processes = processes
    }

    public func sample(metrics: Set<MetricID>, perCore: Bool, topProcesses: Bool) -> SystemSnapshot {
        var s = SystemSnapshot()
        if metrics.contains(.cpu) { s.cpu = cpu.sample(perCore: perCore) }
        if metrics.contains(.memory) { s.memory = memory.sample() }
        if metrics.contains(.network) { s.network = network.sample() }
        if topProcesses { s.processes = processes.sample() }
        return s
    }
}
