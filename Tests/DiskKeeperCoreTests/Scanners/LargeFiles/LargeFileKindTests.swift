import XCTest
@testable import DiskKeeperCore

final class LargeFileKindTests: XCTestCase {
    func testTable() {
        let table: [LargeFileKind: [String]] = [
            .archive: ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "zst", "lz4", "cpio"],
            .diskImageOrInstaller: ["dmg", "pkg", "mpkg", "xip", "iso", "img", "toast", "cdr", "sparseimage"],
            .video: ["mov", "mp4", "m4v", "mkv", "avi", "webm", "mts", "m2ts", "mpg", "mpeg", "wmv", "flv", "hevc", "braw", "r3d"],
            .vmImage: ["vmdk", "vdi", "vhd", "vhdx", "qcow2", "hdd", "ipsw", "ova", "ovf", "utmdisk"],
        ]
        for (kind, exts) in table {
            for e in exts {
                XCTAssertEqual(LargeFileKind.classify(fileName: "x.\(e)"), kind, e)
                XCTAssertEqual(LargeFileKind.classify(fileName: "X.\(e.uppercased())"), kind, e)
            }
        }
    }

    func testEdgeCases() {
        XCTAssertEqual(LargeFileKind.classify(fileName: "archive.tar.gz"), .archive)
        XCTAssertEqual(LargeFileKind.classify(fileName: "backup.tar.xz"), .archive)
        XCTAssertEqual(LargeFileKind.classify(fileName: "backup.tar.zst"), .archive)
        XCTAssertEqual(LargeFileKind.classify(fileName: "README"), .other)
        XCTAssertEqual(LargeFileKind.classify(fileName: "Safari.app"), .other)
        XCTAssertEqual(LargeFileKind.classify(fileName: ".zip"), .other)
        XCTAssertEqual(LargeFileKind.classify(fileName: "data.bin"), .other)
        XCTAssertEqual(LargeFileKind.classify(fileName: "/Users/x/Movies/clip.MOV"), .video)
        XCTAssertEqual(LargeFileKind.classify(fileName: "trailing."), .other)
    }
}
