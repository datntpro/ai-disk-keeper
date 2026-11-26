import XCTest
@testable import DiskKeeperCore

/// M4 invariant 17: media libraries are protected packages by basename, wherever they live.
final class ProtectedMediaLibraryTests: XCTestCase {
    let home = "/Users/tester"
    let tmp = "/var/folders/zz/T/"

    func policy() throws -> ProtectedPaths {
        try ProtectedPaths(homeDirectory: home, temporaryDirectory: tmp, additionalPatterns: [],
                           resolver: FakePathResolver())
    }

    func reason(_ p: ProtectedPaths, _ path: String) -> PathDenial.Reason? { p.check(path).denial?.reason }

    func testMediaLibrariesAreProtected() throws {
        let p = try policy()
        let paths = [
            "\(home)/Pictures/Photos Library.photoslibrary",
            "\(home)/Pictures/iPhoto Library.photolibrary",
            "\(home)/Music/Music/Music Library.musiclibrary",
            "\(home)/Movies/TV/TV Library.tvlibrary",
            "\(home)/Pictures/Aperture Library.aplibrary",
            "\(home)/Movies/iMovie Library.imovielibrary",
            "\(home)/Movies/X.fcpbundle",
            "\(home)/Documents/elsewhere/Moved.photoslibrary",
        ]
        for path in paths { XCTAssertEqual(reason(p, path), .protectedName, path) }
    }

    func testInsideMediaLibraryIsProtected() throws {
        let p = try policy()
        XCTAssertEqual(reason(p, "\(home)/Pictures/Photos Library.photoslibrary/originals/A/IMG_1.HEIC"), .protectedName)
        XCTAssertEqual(reason(p, "\(home)/Movies/X.fcpbundle/Event/media.mov"), .protectedName)
    }

    func testMediaLibraryCaseAndUnicodeFolding() throws {
        let p = try policy()
        XCTAssertEqual(reason(p, "\(home)/Pictures/Photos Library.PhotosLibrary"), .protectedName)
        XCTAssertEqual(reason(p, "\(home)/Pictures/Photos Library.PHOTOSLIBRARY"), .protectedName)
        let nfd = "Bibliothe\u{0300}que Photos.photoslibrary"
        XCTAssertEqual(reason(p, "\(home)/Pictures/\(nfd)"), .protectedName)
    }

    func testMediaFilesOutsideLibrariesStayAllowed() throws {
        let p = try policy()
        for path in ["\(home)/Pictures/IMG_1.HEIC", "\(home)/Movies/clip.mov", "\(home)/Music/song.m4a",
                     "\(home)/Pictures/photoslibrary-notes.txt"] {
            XCTAssertNil(reason(p, path), path)
        }
    }

    func testBundledRulesStillLoadWithoutErrors() throws {
        let fixture = try FixtureHome()
        let loaded = RuleHarness.loadAllBundled(fixture: fixture)
        XCTAssertEqual(loaded.errors.map(\.description), [])
        XCTAssertFalse(loaded.allRules.isEmpty)
    }
}
