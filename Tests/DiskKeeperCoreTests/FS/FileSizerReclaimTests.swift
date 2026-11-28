import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// H6: private (really freed) bytes on APFS, in a temp dir. Clones are real `clonefile(2)` clones.
final class FileSizerReclaimTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private let mib = 1_048_576

    override func setUpWithError() throws { tmp = try TemporaryDirectory() }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private func measure(_ rel: String, probe: (@Sendable (String) -> CloneInfo)? = nil) throws -> SizeReport {
        var o = FileSizer.Options(measurePrivateBytes: true)
        o._cloneProbe = probe
        return try FileSizer(options: o).sizeBlocking(of: tmp.url.appendingPathComponent(rel))
    }

    private func clone(_ from: String, _ to: String) throws {
        try FileManager.default.createDirectory(
            at: tmp.url.appendingPathComponent(to).deletingLastPathComponent(), withIntermediateDirectories: true)
        if clonefile(tmp.path(from), tmp.path(to), 0) != 0 {
            let code = errno
            if code == ENOTSUP { throw XCTSkip("volume does not support clonefile") }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func requireProbe(_ rel: String) throws {
        if case .unknown = CloneProbe.probe(tmp.path(rel)) { throw XCTSkip("volume does not report clone info") }
    }

    func testNotMeasuredByDefault() throws {
        try tmp.file("tree/a.bin", bytes: 2 * mib)
        let r = try FileSizer().sizeBlocking(of: tmp.url.appendingPathComponent("tree"))
        XCTAssertNil(r.privateBytes)
    }

    func testCloneOfOutsideFileFreesAlmostNothingThenAllAfterOriginalGone() throws {
        try tmp.file("outside/orig.bin", contents: Data((0..<(8 * mib)).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try clone("outside/orig.bin", "tree/clone.bin")
        try requireProbe("tree/clone.bin")
        let shared = try measure("tree")
        XCTAssertGreaterThanOrEqual(shared.allocatedBytes, Int64(8 * mib))
        XCTAssertLessThan(shared.privateBytes!, Int64(mib) / 2)
        XCTAssertGreaterThanOrEqual(shared.probedBytes, Int64(8 * mib))
        XCTAssertFalse(shared.privateIsEstimate)

        try FileManager.default.removeItem(atPath: tmp.path("outside/orig.bin"))
        let alone = try measure("tree")
        XCTAssertGreaterThanOrEqual(alone.privateBytes!, Int64(8 * mib))
        XCTAssertLessThanOrEqual(alone.privateBytes!, alone.allocatedBytes)
    }

    func testPartiallyModifiedCloneFreesAboutTheChangedPart() throws {
        try tmp.file("outside/orig.bin", contents: Data((0..<(8 * mib)).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
        try clone("outside/orig.bin", "tree/clone.bin")
        try requireProbe("tree/clone.bin")
        let h = try FileHandle(forWritingTo: tmp.url.appendingPathComponent("tree/clone.bin"))
        try h.write(contentsOf: Data(repeating: 0xEE, count: mib))
        try h.close()
        let r = try measure("tree")
        XCTAssertGreaterThanOrEqual(r.privateBytes!, Int64(mib) - 64 * 1024)
        XCTAssertLessThan(r.privateBytes!, Int64(2 * mib))
    }

    func testHardLinkOutsideTreeFreesNothing() throws {
        try tmp.file("outside/one.bin", bytes: 2 * mib)
        try tmp.hardlink("tree/in.bin", to: "outside/one.bin")
        let r = try measure("tree")
        XCTAssertEqual(r.externallyLinkedFileCount, 1)
        XCTAssertGreaterThan(r.sharedOutsideBytes, 0)
        XCTAssertLessThan(r.privateBytes!, Int64(mib) / 4)     // only the directory's own blocks
    }

    func testHardLinksBothInsideCountedOnce() throws {
        try tmp.file("tree/a.bin", bytes: 2 * mib)
        try tmp.hardlink("tree/b.bin", to: "tree/a.bin")
        let r = try measure("tree")
        XCTAssertEqual(r.hardlinkDuplicateCount, 1)
        XCTAssertEqual(r.sharedOutsideBytes, 0)
        XCTAssertGreaterThanOrEqual(r.privateBytes!, Int64(2 * mib))
        XCTAssertLessThanOrEqual(r.privateBytes!, r.allocatedBytes)
    }

    func testSmallFilesAreNotProbedAndCountAsAllocated() throws {
        for i in 0..<5 { try tmp.file("tree/s\(i).bin", bytes: 4096) }
        let counter = OSAtomicCounter()
        let r = try measure("tree") { _ in counter.bump(); return .unknown }
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(r.probedBytes, 0)
        XCTAssertEqual(r.privateBytes, r.allocatedBytes)
        XCTAssertFalse(r.privateIsEstimate)
    }

    func testUnknownProbeCountsAllocatedAndMarksEstimate() throws {
        try tmp.file("tree/big.bin", bytes: 3 * mib)
        let r = try measure("tree") { _ in .unknown }
        XCTAssertEqual(r.privateBytes, r.allocatedBytes)
        XCTAssertTrue(r.privateIsEstimate)
        let (bytes, estimate) = ScanItem.reclaim(from: r)
        XCTAssertEqual(bytes, r.allocatedBytes)
        XCTAssertTrue(estimate)
    }

    func testPrivateBytesNeverExceedAllocated() throws {
        try tmp.file("tree/big.bin", bytes: 3 * mib)
        let r = try measure("tree") { _ in
            .known(cloneID: 1, refCount: 1, privateBytes: 1 << 40, sharesAllBlocks: false, maySharesBlocks: false)
        }
        XCTAssertLessThanOrEqual(r.privateBytes!, r.allocatedBytes)
    }

    func testRootFileClone() throws {
        try tmp.file("outside/orig.bin", contents: Data((0..<(4 * mib)).map { UInt8(truncatingIfNeeded: $0 &* 13) }))
        try clone("outside/orig.bin", "clone.bin")
        try requireProbe("clone.bin")
        let r = try measure("clone.bin")
        XCTAssertEqual(r.rootKind, .file)
        XCTAssertLessThan(r.privateBytes!, Int64(mib) / 2)
    }
}

final class OSAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
