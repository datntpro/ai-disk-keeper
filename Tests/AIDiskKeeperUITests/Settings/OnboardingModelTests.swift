import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class OnboardingModelTests: XCTestCase {
    private var dir: URL!
    private let env = PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func settings() -> SettingsModel {
        SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("s.json")), environment: env,
                      probe: { .unknown })
    }

    func testFirstRunThenFinishPersists() {
        let s = settings()
        let o = OnboardingModel(settings: s) {}
        XCTAssertTrue(o.isFirstRun)
        o.finish(startScan: false)
        XCTAssertFalse(o.isFirstRun)
        XCTAssertFalse(OnboardingModel(settings: settings()) {}.isFirstRun)
    }

    func testStartScanRequestedExactlyOnce() {
        var count = 0
        let o = OnboardingModel(settings: settings()) { count += 1 }
        o.finish(startScan: true)
        o.finish(startScan: true)
        XCTAssertEqual(count, 1)
    }

    func testNotNowDoesNotScan() {
        var count = 0
        let o = OnboardingModel(settings: settings()) { count += 1 }
        o.finish(startScan: false)
        XCTAssertEqual(count, 0)
    }
}
