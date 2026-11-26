import DiskKeeperCore
import Foundation
@testable import AIDiskKeeperUI

enum LargeOldFix {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let root = "/tmp/fixture-root"

    static func months(_ n: Double) -> Date { now.addingTimeInterval(-n * 30.5 * 86_400) }

    static func file(_ path: String, mb: Int64, kind: LargeFileKind = .other, months m: Double = 12,
                     source: LastOpenedSource = .modified, match: String? = nil, links: UInt16 = 1,
                     sharesAll: Bool = false, mounted: Bool = false) -> LargeFile {
        let d = months(m)
        return LargeFile(path: root + "/" + path, logicalBytes: mb * 1_000_000, allocatedBytes: mb * 1_000_000,
                         reclaimableBytes: mb * 1_000_000, kind: kind,
                         dates: FileDates(spotlightLastUsed: nil, accessed: d, modified: d, created: d), lastOpened: d,
                         lastOpenedSource: source, installedAppMatch: match, sharesStorage: links > 1 || sharesAll,
                         sharesAllStorage: sharesAll, linkCount: links, isMountedImage: mounted)
    }

    static var sample: [LargeFile] {
        [
            file("Documents/Archive-2024.zip", mb: 9000, kind: .archive, months: 14),
            file("Downloads/Xcode_16.2.xip", mb: 2900, kind: .diskImageOrInstaller, months: 8, match: "Xcode"),
            file("Movies/demo.mov", mb: 1200, kind: .video, months: 12),
            file("Downloads/Docker.dmg", mb: 610, kind: .diskImageOrInstaller, months: 7, match: "Docker"),
            file("Movies/recent.mov", mb: 800, kind: .video, months: 1),
            file("Documents/small.bin", mb: 200, kind: .other, months: 20),
            file("Documents/linked.bin", mb: 700, kind: .other, months: 9, links: 2),
        ]
    }

    static func report(_ files: [LargeFile] = sample) -> LargeFileReport { LargeFileReport(files: files) }

    @MainActor static func wait(_ cond: () -> Bool) async {
        for _ in 0..<600 { if cond() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

@MainActor
final class FakeFinder: FinderRevealing {
    private(set) var revealed: [URL] = []
    func reveal(_ url: URL) { revealed.append(url) }
}
