import XCTest
@testable import DiskKeeperCore

final class AppQuitPolicyTests: XCTestCase {
    private func app(_ id: String = "com.dev.notely", team: String? = "TEAM1", viewOnly: Bool = false,
                     path: String = "/h/Applications/Notely.app", selfID: String? = "com.aidiskkeeper.app",
                     selfPath: String? = "/h/Applications/AI Disk Keeper.app") -> AppQuitRefusal? {
        AppQuitPolicy.refusal(bundleID: id, teamID: team, viewOnly: viewOnly, bundlePath: path, selfBundleID: selfID, selfBundlePath: selfPath)
    }

    private func inst(pid: pid_t = 500, id: String? = "com.dev.notely", owner: uid_t? = 501, location: String? = nil) -> AppQuitRefusal? {
        AppQuitPolicy.refusal(pid: pid, bundleID: id, ownerUID: owner, currentUID: 501, selfPID: 999, location: location,
                              selfBundlePath: "/h/Applications/AI Disk Keeper.app")
    }

    func testAppLevel() {
        XCTAssertNil(app())
        XCTAssertEqual(app(viewOnly: true), .viewOnly)
        XCTAssertEqual(app("com.apple.Safari"), .appleOrSystem)
        XCTAssertEqual(app(team: "59GAB85EFG"), .appleOrSystem)
        XCTAssertEqual(app("com.aidiskkeeper.app"), .selfApp)
        XCTAssertEqual(app(path: "/h/Applications/AI Disk Keeper.app"), .selfApp)
        XCTAssertEqual(app(path: "/h/applications/ai disk keeper.app"), .selfApp)
        XCTAssertNil(app(selfID: nil, selfPath: nil))
    }

    func testInstanceLevel() {
        XCTAssertNil(inst())
        XCTAssertEqual(inst(pid: 1), .appleOrSystem)
        XCTAssertEqual(inst(pid: 0), .appleOrSystem)
        XCTAssertEqual(inst(pid: 999), .selfApp)
        XCTAssertEqual(inst(id: "com.apple.finder"), .appleOrSystem)
        XCTAssertEqual(inst(location: "/h/Applications/AI Disk Keeper.app/Contents/Helpers/X.app"), .selfApp)
        XCTAssertEqual(inst(owner: 502), .otherUser)
        XCTAssertEqual(inst(owner: nil), .ownershipUnknown)
        XCTAssertNil(inst(location: "/h/Applications/AI Disk Keeper.app2/X"))
    }
}
