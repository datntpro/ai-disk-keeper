import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class ContentHasherTests: XCTestCase {
    private func identity(_ path: String) throws -> FileIdentity {
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        return FileIdentity(device: Int32(truncatingIfNeeded: st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size))
    }

    func testFullDigestMatchesCryptoKit() async throws {
        let tmp = try TemporaryDirectory()
        for size in [0, 1, 65_536, 131_072, 3_000_001] {
            let d = DupFix.data(seed: UInt64(size) + 1, count: size)
            let p = try DupFix.write(tmp.path("f\(size)"), d)
            let outcome = try await ContentHasher.fullDigest(path: p, identity: try identity(p))
            XCTAssertEqual(outcome, .digest(DupFix.hex(d), bytesRead: Int64(size)), "size \(size)")
        }
    }

    func testPartialDigestCoversSizeHeadAndTail() async throws {
        let tmp = try TemporaryDirectory()
        let d = DupFix.data(seed: 42, count: 300_000)
        let p = try DupFix.write(tmp.path("f"), d)
        var expected = Data()
        var be = UInt64(d.count).bigEndian
        withUnsafeBytes(of: &be) { expected.append(contentsOf: $0) }
        expected.append(d.prefix(65_536)); expected.append(d.suffix(65_536))
        let outcome = try await ContentHasher.partialDigest(path: p, identity: try identity(p))
        XCTAssertEqual(outcome, .digest(DupFix.hex(expected), bytesRead: 131_072))
        // a change in the middle does not show in the partial digest, a change in the tail does
        var mid = d; mid[150_000] ^= 1
        try DupFix.write(p, mid)
        let id = try identity(p)
        let o2 = try await ContentHasher.partialDigest(path: p, identity: id)
        XCTAssertEqual(o2, outcome)
        var tail = d; tail[299_999] ^= 1
        try DupFix.write(p, tail)
        let o3 = try await ContentHasher.partialDigest(path: p, identity: try identity(p))
        XCTAssertNotEqual(o3, outcome)
    }

    func testIdentityMismatchIsChanged() async throws {
        let tmp = try TemporaryDirectory()
        let p = try DupFix.write(tmp.path("f"), DupFix.data(seed: 1, count: 2_000_000))
        let old = try identity(p)
        // swapped for another file: new inode
        try FileManager.default.removeItem(atPath: p)
        try DupFix.write(p, DupFix.data(seed: 1, count: 2_000_000))
        let swapped = try await ContentHasher.fullDigest(path: p, identity: old)
        XCTAssertEqual(swapped, .changed)
        // resized
        let id = try identity(p)
        let wrongSize = FileIdentity(device: id.device, inode: id.inode, size: id.size + 1)
        let resized = try await ContentHasher.fullDigest(path: p, identity: wrongSize)
        XCTAssertEqual(resized, .changed)
    }

    func testSymlinkIsNotFollowed() async throws {
        let tmp = try TemporaryDirectory()
        let target = try DupFix.write(tmp.path("target"), DupFix.data(seed: 1, count: 2_000_000))
        let link = tmp.path("link")
        XCTAssertEqual(symlink(target, link), 0)
        let outcome = try await ContentHasher.fullDigest(path: link, identity: try identity(target))
        XCTAssertEqual(outcome, .changed)
    }

    func testMissingFileIsChangedAndDirectoryIsNotRead() async throws {
        let tmp = try TemporaryDirectory()
        let gone = try await ContentHasher.fullDigest(path: tmp.path("nope"), identity: FileIdentity(device: 0, inode: 1, size: 5))
        XCTAssertEqual(gone, .changed)
        let dir = tmp.path("d"); try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let asDir = try await ContentHasher.fullDigest(path: dir, identity: try identity(dir))
        XCTAssertEqual(asDir, .changed)
    }
}
