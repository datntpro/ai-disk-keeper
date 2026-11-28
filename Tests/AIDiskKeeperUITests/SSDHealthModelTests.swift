import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

private final class FakeReader: SSDHealthReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    let health: SSDHealth?
    init(_ h: SSDHealth?) { health = h }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    func read() -> SSDHealth? { lock.lock(); _reads += 1; lock.unlock(); return health }
}

private struct FakeStats: DiskStatisticsReading {
    func read() -> DiskStatistics? { DiskStatistics(bytesRead: 1, bytesWritten: 2_100, totalTimeReadNs: 0, totalTimeWriteNs: 0) }
}

@MainActor
final class SSDHealthModelTests: XCTestCase {
    private let sample = SSDHealth(criticalWarning: 0, temperatureCelsius: 29, availableSparePercent: 100, spareThresholdPercent: 99,
                                   percentageUsed: 1, bytesWritten: 41_500_000_000_000, bytesRead: 1, powerCycles: 1,
                                   powerOnHours: 1, unsafeShutdowns: 0, mediaErrors: 0)

    func testFailureIsUnavailable() async {
        let model = SSDHealthModel(reader: FakeReader(nil), statistics: FakeStats())
        model.refreshIfNeeded()
        await model.settle()
        XCTAssertEqual(model.state, .unavailable)
    }

    func testReadyCarriesSinceBootAndIsCachedForTenMinutes() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let reader = FakeReader(sample)
        let model = SSDHealthModel(reader: reader, statistics: FakeStats(), clock: { now })
        model.refreshIfNeeded()
        await model.settle()
        XCTAssertEqual(model.state, .ready(sample, writtenSinceBoot: 2_100))
        now += 599
        model.refreshIfNeeded()
        await model.settle()
        XCTAssertEqual(reader.reads, 1, "cached")
        now += 2
        model.refreshIfNeeded()
        await model.settle()
        XCTAssertEqual(reader.reads, 2)
    }
}

@MainActor
final class SSDHealthSuiteStateTests: XCTestCase {
    func testCachedReadingSurvivesSwitchingModules() async {
        let env = AppEnvironment(pathEnvironment: PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp"),
                                 makeScanEngine: { FakeScanEngine(.scripted([])) })
        let suite = SuiteModel(env: env)
        let health = SSDHealth(criticalWarning: 0, temperatureCelsius: 29, availableSparePercent: 100, spareThresholdPercent: 99,
                               percentageUsed: 1, bytesWritten: 1, bytesRead: 1, powerCycles: 1, powerOnHours: 1,
                               unsafeShutdowns: 0, mediaErrors: 0)
        let reader = FakeReader(health)
        let first = suite.state(.storage) {
            StorageModel(load: { StorageFix.overview() }, ssdHealth: SSDHealthModel(reader: reader, statistics: FakeStats()))
        }
        first.ssdHealth.refreshIfNeeded()
        await first.ssdHealth.settle()
        // Leaving Storage and coming back rebuilds the view; the module's model comes from suite state again.
        let again = StorageModule.model(env: env, suite: suite)
        XCTAssertTrue(again === first)
        again.ssdHealth.refreshIfNeeded()
        await again.ssdHealth.settle()
        XCTAssertEqual(reader.reads, 1, "no second device read within the TTL")
        XCTAssertEqual(again.ssdHealth.state, .ready(health, writtenSinceBoot: 2_100))
    }
}
