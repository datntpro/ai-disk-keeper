import XCTest
@testable import DiskKeeperCore

private struct FakeVolumes: VolumeInfoProviding {
    var delay: Duration = .zero
    var missing: Set<String> = []
    var devices: [String: Int64] = ["/": 1, "/System/Volumes/Data": 2]
    func info(forPath path: String) async throws -> VolumeInfo {
        try await Task.sleep(for: delay)
        if missing.contains(path) { throw VolumeInfoError.unavailable(path: path, reason: "missing") }
        return VolumeInfo(mountPath: path, totalBytes: 1000, availableBytes: 100, usedBytesThisVolume: 300, deviceID: devices[path])
    }
}

final class StorageOverviewTests: XCTestCase {
    private func service(_ fx: FixtureHome, volumes: FakeVolumes, snapshotDelay: Int = 0) throws -> StorageOverviewService {
        let tmp = try TemporaryDirectory()
        let script = try tmp.file("t.sh", contents: Data("#!/bin/sh\nsleep 0.\(snapshotDelay)\necho com.apple.os.update-1\n".utf8))
        try tmp.chmod("t.sh", 0o755)
        withExtendedLifetime(tmp) {}
        keep.append(tmp)
        return StorageOverviewService(environment: fx.env, volumes: volumes, snapshots: LocalSnapshotLister(executable: script),
                                      trash: TrashSizer(environment: fx.env) { _ in
                                          try await Task.sleep(for: .milliseconds(100))
                                          throw FileSizerError.rootNotFound(path: "x")
                                      })
    }
    private var keep: [TemporaryDirectory] = []

    func testAssemblesOverview() async throws {
        let fx = try FixtureHome()
        let o = try await service(fx, volumes: FakeVolumes()).overview()
        XCTAssertEqual(o.dataVolume.mountPath, "/System/Volumes/Data")
        XCTAssertEqual(o.systemVolume?.mountPath, "/")
        XCTAssertEqual(o.snapshots, .listed([LocalSnapshot(name: "com.apple.os.update-1", date: nil, kind: .osUpdate)]))
        XCTAssertEqual(o.trash.state, .measured)
    }

    func testMissingDataVolumeFallsBackToRoot() async throws {
        let fx = try FixtureHome()
        let o = try await service(fx, volumes: FakeVolumes(missing: ["/System/Volumes/Data"])).overview()
        XCTAssertEqual(o.dataVolume.mountPath, "/")
        XCTAssertNil(o.systemVolume)
    }

    func testSameDeviceMeansNoSystemVolume() async throws {
        let fx = try FixtureHome()
        let o = try await service(fx, volumes: FakeVolumes(devices: ["/": 7, "/System/Volumes/Data": 7])).overview()
        XCTAssertNil(o.systemVolume)
    }

    func testPartsRunConcurrently() async throws {
        let fx = try FixtureHome()
        let s = try service(fx, volumes: FakeVolumes(delay: .milliseconds(100)))
        let start = ContinuousClock.now
        _ = try await s.overview()
        // volumes (2 x 100ms sequential) || snapshots || trash(100ms): well under the ~500ms a serial run would take.
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(450))
    }

    func testCancellationPropagates() async throws {
        let fx = try FixtureHome()
        let s = try service(fx, volumes: FakeVolumes(delay: .seconds(5)))
        let task = Task { try await s.overview() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
    }
}
