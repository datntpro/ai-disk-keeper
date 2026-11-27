import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

private struct NoProcesses: ProcessTableReading { func snapshot() -> ProcessTableSnapshot? { nil } }
private struct NoDisk: DiskStatisticsReading { func read() -> DiskStatistics? { nil } }

@MainActor
final class HostStatusPublisherTests: XCTestCase {
    private var dir: URL!
    private let env = PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HostStatusPublisherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func settingsModel() -> SettingsModel {
        SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("settings.json")), environment: env, probe: { .unknown })
    }

    private func publisher(_ settings: SettingsModel) -> (HostStatusPublisher, URL) {
        let url = dir.appendingPathComponent("AIDiskKeeper/status.json")
        let sampler = HostLoadSampler(table: NoProcesses(), disk: NoDisk(), attribution: WorktreeAttribution(home: dir.path),
                                      freeSpace: { FreeSpaceStatus(freeBytes: 400_000_000_000, totalBytes: 500_000_000_000, thresholdPercent: 15, trend: nil) },
                                      memoryPressure: { .normal })
        let p = HostStatusPublisher(settings: settings, writer: HostStatusWriter(fileURL: url), sampler: sampler,
                                    composer: HostStatusComposer(version: "t"), observeTermination: false, sleeper: { _ in try? await Task.sleep(for: .seconds(3600)) })
        return (p, url)
    }

    func testDefaultIsOn() {
        XCTAssertTrue(settingsModel().settings.publishHostStatus)
    }

    func testPublishOnceWritesAndSettingOffRemovesTheFile() async throws {
        let settings = settingsModel()
        let (p, url) = publisher(settings)
        await p.publishOnce()
        let status = try HostStatus.makeDecoder().decode(HostStatus.self, from: Data(contentsOf: url))
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.level, .ok)
        XCTAssertEqual(status.disk?.freePercent, 80)
        settings.setPublishHostStatus(false)
        p.apply()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await p.publishOnce()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "off means no write")
        p.stop()
    }

    func testStartWithSettingOffStartsNoLoopAndTurningOnStartsOne() async throws {
        let settings = settingsModel()
        settings.setPublishHostStatus(false)
        let (p, _) = publisher(settings)
        p.start()
        XCTAssertFalse(p.isPublishing)
        settings.setPublishHostStatus(true)
        p.apply()
        XCTAssertTrue(p.isPublishing)
        p.stop()
        XCTAssertFalse(p.isPublishing)
    }

    func testSettingsModelInstallsAndRemovesOnlyInTempHome() throws {
        let binary = dir.appendingPathComponent("App.app/Contents/MacOS/adk")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: binary); chmod(binary.path, 0o755)
        let m = HostStatusSettingsModel(statusFileURL: dir.appendingPathComponent("status.json"),
                                        installer: CLIInstaller(home: dir.path, binary: binary, pathVariable: "/usr/bin"))
        XCTAssertEqual(m.state, .notInstalled)
        m.install()
        XCTAssertEqual(m.state, .installed)
        XCTAssertTrue(m.needsPathHint)
        m.remove()
        XCTAssertEqual(m.state, .notInstalled)
        XCTAssertNil(m.errorMessage)
    }
}
