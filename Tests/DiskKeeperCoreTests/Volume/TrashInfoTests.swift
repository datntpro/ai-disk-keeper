import XCTest
@testable import DiskKeeperCore

final class TrashInfoTests: XCTestCase {
    func testMeasuredMatchesFileSizer() async throws {
        let fx = try FixtureHome()
        _ = try fx.file(".Trash/a", bytes: 5000)
        _ = try fx.file(".Trash/b", bytes: 5000)
        _ = try fx.file(".Trash/sub/c", bytes: 5000)
        let info = try await TrashSizer(environment: fx.env).measure()
        let expected = try FileSizer().sizeBlocking(of: URL(fileURLWithPath: fx.home + "/.Trash")).allocatedBytes
        XCTAssertEqual(info.state, .measured)
        XCTAssertEqual(info.allocatedBytes, expected)
        XCTAssertEqual(info.itemCount, 3)
        XCTAssertEqual(info.path, fx.home + "/.Trash")
    }

    func testMissingTrashIsZero() async throws {
        let fx = try FixtureHome()
        let info = try await TrashSizer(environment: fx.env).measure()
        XCTAssertEqual(info, TrashInfo(path: fx.home + "/.Trash", state: .measured, allocatedBytes: 0, itemCount: 0))
    }

    func testErrorMapping() {
        XCTAssertEqual(TrashInfo.State.from(error: FileSizerError.rootInaccessible(path: "/x", errno: EPERM)), .needsFullDiskAccess)
        XCTAssertEqual(TrashInfo.State.from(error: FileSizerError.rootInaccessible(path: "/x", errno: EACCES)), .unavailable(errno: EACCES))
        XCTAssertEqual(TrashInfo.State.from(error: CocoaError(.fileReadUnknown)), .unavailable(errno: nil))
    }

    func testInjectedSizerErrorsBecomeStates() async throws {
        let fx = try FixtureHome()
        let fda = TrashSizer(environment: fx.env) { _ in throw FileSizerError.rootInaccessible(path: "x", errno: EPERM) }
        let r = try await fda.measure()
        XCTAssertEqual(r.state, .needsFullDiskAccess)
        XCTAssertNil(r.allocatedBytes)
    }

    func testCancellationPropagates() async throws {
        let fx = try FixtureHome()
        let s = TrashSizer(environment: fx.env) { _ in throw CancellationError() }
        do { _ = try await s.measure(); XCTFail() } catch is CancellationError {}
    }
}
