import XCTest
@testable import DiskKeeperCore

final class AppBundleReaderTests: XCTestCase {
    private var fx: FixtureHome!
    override func setUpWithError() throws { fx = try FixtureHome() }

    private func path(_ n: String) -> String { fx.tmp.path("Apps/\(n)") }

    func testReadsXmlAndBinaryPlists() throws {
        for binary in [false, true] {
            let p = try AppFixtures.makeApp(at: path("A\(binary).app"), bundleID: "com.foo.app", name: "Foo",
                                            bundleName: "FooName", binary: binary)
            let info = try AppBundleReader.read(bundlePath: p)
            XCTAssertEqual(info.bundleID, "com.foo.app")
            XCTAssertEqual(info.displayName, "Foo")
            XCTAssertEqual(info.bundleName, "FooName")
            XCTAssertEqual(info.version, "1.2")
            XCTAssertEqual(info.executable, "exe")
        }
    }

    func testMissingPlist() throws {
        let p = try AppFixtures.makeApp(at: path("M.app"), bundleID: nil, omitPlist: true)
        XCTAssertThrowsError(try AppBundleReader.read(bundlePath: p)) {
            XCTAssertEqual($0 as? AppBundleReadError, .missingPlist)
        }
    }

    func testBadPlist() throws {
        let p = try AppFixtures.makeApp(at: path("B.app"), bundleID: nil, plist: Data("not a plist".utf8))
        XCTAssertThrowsError(try AppBundleReader.read(bundlePath: p)) {
            guard case .corruptPlist? = $0 as? AppBundleReadError else { return XCTFail("\($0)") }
        }
    }

    func testNoBundleIDReadsAsNil() throws {
        let p = try AppFixtures.makeApp(at: path("N.app"), bundleID: nil)
        XCTAssertNil(try AppBundleReader.read(bundlePath: p).bundleID)
    }

    func testReceiptAndSymlinkDetection() throws {
        let r = try AppFixtures.makeApp(at: path("R.app"), bundleID: "com.foo.r", receipt: true)
        let n = try AppFixtures.makeApp(at: path("Nr.app"), bundleID: "com.foo.n")
        XCTAssertTrue(AppBundleReader.hasAppStoreReceipt(bundlePath: r))
        XCTAssertFalse(AppBundleReader.hasAppStoreReceipt(bundlePath: n))
        let link = try fx.tmp.symlink("Apps/L.app", to: r).path
        XCTAssertEqual(AppBundleReader.entryKind(link)?.isSymlink, true)
        XCTAssertEqual(AppBundleReader.entryKind(link)?.isDirectory, true)
        XCTAssertEqual(AppBundleReader.entryKind(r)?.isSymlink, false)
    }

    func testAppNameCaseInsensitive() {
        XCTAssertTrue(AppInventoryScanner.isAppName("Foo.APP"))
        XCTAssertTrue(AppInventoryScanner.isAppName("Foo.app"))
        XCTAssertFalse(AppInventoryScanner.isAppName(".app"))
        XCTAssertFalse(AppInventoryScanner.isAppName("Foo.application"))
    }
}
