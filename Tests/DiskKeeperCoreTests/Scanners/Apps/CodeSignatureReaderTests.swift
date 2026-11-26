import XCTest
@testable import DiskKeeperCore

final class CodeSignatureReaderTests: XCTestCase {
    func testAdHocSignedFixtureIsUnsigned() throws {
        let fm = FileManager.default
        try XCTSkipUnless(fm.isExecutableFile(atPath: "/usr/bin/codesign"), "codesign unavailable")
        let fx = try FixtureHome()
        let app = fx.tmp.path("T.app")
        try AppFixtures.makeApp(at: app, bundleID: "com.t.sig")
        try fm.removeItem(atPath: app + "/Contents/MacOS/exe")
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app + "/Contents/MacOS/exe")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "-s", "-", app]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try XCTSkipIf(p.terminationStatus != 0, "ad-hoc signing failed")
        XCTAssertEqual(SecStaticCodeSignatureReader().source(ofBundleAt: app), .unsigned)
    }

    func testUnsignedFixtureIsNotApple() throws {
        let fx = try FixtureHome()
        let app = try AppFixtures.makeApp(at: fx.tmp.path("U.app"), bundleID: "com.t.unsigned")
        let source = SecStaticCodeSignatureReader().source(ofBundleAt: app)
        XCTAssertNotEqual(source, .apple)
    }
}
