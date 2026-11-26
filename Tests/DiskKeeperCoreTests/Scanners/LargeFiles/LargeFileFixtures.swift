import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

struct FakeLastOpened: LastOpenedProviding {
    var table: [String: FileDates] = [:]
    var fallback: FileDates?
    func dates(for path: String) -> FileDates? { table[path] ?? fallback }
}

struct FakeMountedImages: MountedImageProbing {
    var paths: Set<String> = []
    var error: (any Error)?
    func mountedImagePaths() async throws -> Set<String> {
        if let error { throw error }
        return paths
    }
}

struct FakeApps: InstalledAppNamesProviding {
    var apps: [String]
    func names() -> [String: String] {
        Dictionary(apps.map { (ApplicationsFolderNames.normalize($0), $0) }, uniquingKeysWith: { a, _ in a })
    }
}

enum LargeFix {
    static let day: TimeInterval = 86_400
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let mb: Int64 = 1_000_000

    static func old(_ days: Double = 400) -> FileDates {
        let d = now.addingTimeInterval(-days * day)
        return FileDates(spotlightLastUsed: nil, accessed: d, modified: d, created: d)
    }

    /// Sparse file: big logical size, no disk cost.
    @discardableResult
    static func sparse(_ path: String, logical: Int64) throws -> String {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(logical)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return path
    }

    static func scanner(_ fx: FixtureHome, minimum: Int64 = 100 * mb, apps: [String] = [],
                        dates: FakeLastOpened = FakeLastOpened(fallback: old()),
                        mounted: FakeMountedImages = FakeMountedImages(),
                        configure: (inout LargeFileOptions) -> Void = { _ in }) -> LargeFileScanner {
        var o = LargeFileOptions(environment: fx.env)
        o.minimumBytes = minimum
        configure(&o)
        var s = LargeFileScanner(options: o, lastOpened: dates, appNames: FakeApps(apps: apps), mountedImages: mounted, tree: { throw CancellationError() })
        s._cloneProbe = { _ in .known(cloneID: 1, refCount: 1, privateBytes: 0, sharesAllBlocks: false, maySharesBlocks: false) }
        return s
    }

    static func report(_ fx: FixtureHome, minimum: Int64 = 100 * mb, apps: [String] = [],
                       dates: FakeLastOpened = FakeLastOpened(fallback: old())) async throws -> LargeFileReport {
        let tree = try await IndexTest.index(fx)
        return try await scanner(fx, minimum: minimum, apps: apps, dates: dates).report(tree: tree, now: now)
    }

    /// A tree with hand-made records (flags the real walker can't produce on a temp volume, such as dataless).
    static func tree(root: String, files: [(path: String, flags: NodeFlags, nodeFlags: NodeFlags, bytes: Int64, inode: UInt64)]) -> DiskTree {
        let b = DiskTreeBuilder()
        let rootID = b.addNode(parent: -1, name: "", flags: .directory)
        var dirs: [String: Int32] = ["": rootID]
        for f in files {
            let comps = f.path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            var parent = rootID
            var key = ""
            for c in comps.dropLast() {
                key += "/" + c
                if let d = dirs[key] { parent = d } else {
                    parent = b.addNode(parent: parent, name: c, flags: .directory)
                    dirs[key] = parent
                }
            }
            let id = b.addNode(parent: parent, name: comps.last!, flags: f.nodeFlags.union(.file), allocated: f.bytes, logical: f.bytes, fileCount: 1)
            b.records.append(FileRecord(node: DiskNodeID(raw: id), device: 1, inode: f.inode, linkCount: 1,
                                        logicalBytes: f.bytes, allocatedBytes: f.bytes, modified: old().modified,
                                        created: old().created, flags: f.flags))
        }
        return b.freeze(rootPath: root, physicalRootPath: root, scope: .folder(root), createdAt: Date(),
                        stats: IndexStats(), firmlinks: .empty)
    }
}
