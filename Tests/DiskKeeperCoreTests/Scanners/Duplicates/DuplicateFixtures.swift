import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// Helpers for the duplicate tests. Everything lives in a `FixtureHome`/`TemporaryDirectory`; nothing reads
/// the real home.
enum DupFix {
    static let mb = 1_500_000

    /// Deterministic pseudo-random bytes (xorshift), so different seeds never collide.
    static func data(seed: UInt64, count: Int) -> Data {
        var s = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var out = Data(count: count)
        out.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in 0..<words.count { s ^= s << 13; s ^= s >> 7; s ^= s << 17; words[i] = s }
            for i in (words.count * 8)..<count { s ^= s << 13; s ^= s >> 7; s ^= s << 17; raw[i] = UInt8(truncatingIfNeeded: s) }
        }
        return out
    }

    @discardableResult
    static func write(_ path: String, _ bytes: Data) throws -> String {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: bytes) else { throw CocoaError(.fileWriteUnknown) }
        return path
    }

    /// `clonefile(2)`; skips the test where the volume cannot clone.
    static func clone(_ src: String, _ dst: String) throws {
        try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        if clonefile(src, dst, 0) != 0 {
            if errno == ENOTSUP { throw XCTSkip("volume does not support clonefile") }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Sets the birth time only (setting mtime to an earlier date would drag the birth time along).
    static func setBirthTime(_ path: String, _ date: Date) throws {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var ts = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        guard setattrlist(path, &list, &ts, MemoryLayout<timespec>.size, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func options(_ fx: FixtureHome) -> DuplicateOptions {
        var o = DuplicateOptions(environment: fx.env)
        o.minimumLogicalBytes = 1_000_000
        return o
    }

    static func find(_ fx: FixtureHome, options: DuplicateOptions? = nil) async throws -> DuplicateReport {
        let tree = try await IndexTest.index(fx)
        return try await DuplicateFinder(options: options ?? Self.options(fx)).find(in: tree)
    }

    static func paths(_ g: DuplicateGroup) -> [String] { g.members.map(\.path) }

    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func openFDCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }
}
