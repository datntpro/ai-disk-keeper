import DiskKeeperCore
import Foundation
import XCTest
@testable import AIDiskKeeperUI

/// Counts sampler calls across the actor boundary.
final class CallCounter: @unchecked Sendable {
    fileprivate let lock = NSLock()
    fileprivate var counts: [String: Int] = [:]
    private var _cpu = 0.3, _mem = 0.5
    func hit(_ k: String) { lock.lock(); counts[k, default: 0] += 1; lock.unlock() }
    func count(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[k] ?? 0 }
    var cpu: Double { get { lock.lock(); defer { lock.unlock() }; return _cpu } set { lock.lock(); _cpu = newValue; lock.unlock() } }
    var mem: Double { get { lock.lock(); defer { lock.unlock() }; return _mem } set { lock.lock(); _mem = newValue; lock.unlock() } }
}

struct FakeCPU: CPUSampling {
    let c: CallCounter
    mutating func sample(perCore: Bool) -> SampleResult<CPUReading> {
        c.hit("cpu"); if perCore { c.hit("cpuPerCore") }
        return .value(CPUReading(total: c.cpu, user: c.cpu * 0.7, system: c.cpu * 0.3, perCore: perCore ? [0.1, 0.2, 0.3, 0.4] : []))
    }
}
struct FakeMemory: MemorySampling {
    let c: CallCounter
    mutating func sample() -> SampleResult<MemoryReading> {
        c.hit("memory")
        let total: UInt64 = 16 << 30
        return .value(MemoryReading(totalBytes: total, appBytes: UInt64(Double(total) * c.mem * 0.6), wiredBytes: UInt64(Double(total) * c.mem * 0.3),
                                    compressedBytes: UInt64(Double(total) * c.mem * 0.1), swapUsedBytes: 1 << 28, pressure: .normal))
    }
}
struct FakeNetwork: NetworkSampling {
    let c: CallCounter
    var fail = false
    mutating func sample() -> SampleResult<NetworkReading> {
        c.hit("network")
        return fail ? .failed : .value(NetworkReading(down: 1_200_000, up: 24_000, interfaceName: "en0", interfaceDisplayName: "Wi-Fi"))
    }
}
struct FakeProcesses: ProcessSampling {
    let c: CallCounter
    mutating func sample() -> [ProcessUsage] {
        c.hit("processes")
        return [ProcessUsage(pid: 1, name: "yes", cpuPercent: 99, memoryBytes: 1 << 20), ProcessUsage(pid: 2, name: "Xcode", cpuPercent: 12, memoryBytes: 4 << 30)]
    }
}

/// Virtual time: tests advance it by hand, so ten minutes cost nothing.
final class VirtualTime: @unchecked Sendable {
    var now: Duration = .zero
}

@MainActor
struct MonitorRig {
    let counter = CallCounter()
    let probeCalls = CallCounter()
    let time = VirtualTime()
    let settings: SettingsModel
    let menuBar: MenuBarModel
    let monitor: SystemMonitorModel
    let scheduler: MonitorScheduler
    let storageLoads = CallCounter()
    let renders = CallCounter()

    init(failNetwork: Bool = false, testCase: XCTestCaseHost? = nil) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("adk-t50-\(UUID().uuidString).json")
        let settings = SettingsModel(store: SettingsStore(fileURL: file), environment: .current(), probe: { .unknown })
        let probeCalls = self.probeCalls, storageLoads = self.storageLoads, renders = self.renders, counter = self.counter
        let care = CareRig()
        let name = "T50-\(UUID().uuidString)"
        let menuBar = MenuBarModel(
            storage: StorageModel(load: { storageLoads.hit("load"); return StorageFix.overview() }),
            care: care.model, scan: care.scan, settings: settings, notifier: SilentLowSpaceNotifier(),
            defaults: UserDefaults(suiteName: name)!,
            probe: { probeCalls.hit("probe"); return VolumeCapacity(free: 100 << 30, total: 500 << 30) })
        let monitor = SystemMonitorModel(settings: settings, menuBar: menuBar, now: { 0 },
                                         renderLabel: { renders.hit("render"); return MenuBarLabelRenderer.render($0) })
        renders.reset("render")
        let time = self.time
        self.settings = settings
        self.menuBar = menuBar
        self.monitor = monitor
        self.scheduler = MonitorScheduler(
            monitor: monitor, menuBar: menuBar, settings: settings,
            sampler: SystemSampler(cpu: FakeCPU(c: counter), memory: FakeMemory(c: counter),
                                   network: FakeNetwork(c: counter, fail: failNetwork), processes: FakeProcesses(c: counter)),
            clock: { time.now }, sleeper: { _ in })
        _ = care
    }

    /// Steps virtual time through `scheduler.tick()` for `minutes`, the way the loop would.
    func run(minutes: Double) async {
        let end = time.now + .seconds(minutes * 60)
        while time.now < end {
            await scheduler.tick()
            time.now += min(scheduler.nextDelay(), .seconds(3600))
        }
    }
}

typealias XCTestCaseHost = AnyObject

extension CallCounter {
    func reset(_ k: String) { lock.lock(); counts[k] = 0; lock.unlock() }
}
