import XCTest
@testable import DiskKeeperCore

final class PackageDetectorTests: XCTestCase {
    func testPositives() {
        for n in ["Foo.app", "Foo.APP", "x.photoslibrary", "y.xcarchive", "z.sparsebundle", "a.framework", "My Lib.musiclibrary"] {
            XCTAssertTrue(PackageDetector.isPackage(name: n), n)
        }
    }

    func testNegatives() {
        for n in ["app", "foo.appx", ".app", "folder", "notes.txt", "a.app.bak", ""] {
            XCTAssertFalse(PackageDetector.isPackage(name: n), n)
        }
    }
}
