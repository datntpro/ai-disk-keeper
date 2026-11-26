import XCTest
@testable import DiskKeeperCore

final class FirmlinkMapTests: XCTestCase {
    let sample = """
    /Applications\tApplications
    /Library\tLibrary
    /Users\tUsers
    /usr/local\tusr/local
    # comment
    garbage line without tab
    relative\tfoo
    /x\t/absolute-second
    """

    func testParseIgnoresMalformedLines() {
        let m = FirmlinkMap.parse(sample)
        XCTAssertEqual(m.links.count, 4)
    }

    func testDisplayPathMapping() {
        let m = FirmlinkMap.parse(sample)
        XCTAssertEqual(m.displayPath("/System/Volumes/Data/Users/me/x"), "/Users/me/x")
        XCTAssertEqual(m.displayPath("/System/Volumes/Data/usr/local/bin"), "/usr/local/bin")
        XCTAssertEqual(m.displayPath("/System/Volumes/Data/Users"), "/Users")
    }

    func testUnknownFirstComponentUnchanged() {
        let m = FirmlinkMap.parse(sample)
        XCTAssertEqual(m.displayPath("/System/Volumes/Data/.Spotlight-V100/a"), "/System/Volumes/Data/.Spotlight-V100/a")
        XCTAssertEqual(m.displayPath("/Users/me"), "/Users/me")
        XCTAssertEqual(m.displayPath("/System/Volumes/Data"), "/System/Volumes/Data")
    }

    func testLoadMissingFileIsEmpty() {
        XCTAssertEqual(FirmlinkMap.load(path: "/nonexistent/firmlinks").links.count, 0)
    }
}
