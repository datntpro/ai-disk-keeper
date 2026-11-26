import Foundation

/// What a large file probably is, by extension only (the content is never read). Drives the summary cards.
public enum LargeFileKind: String, Codable, CaseIterable, Sendable {
    case archive, diskImageOrInstaller, video, vmImage, other

    static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "zst", "lz4", "cpio",
    ]
    static let diskImageExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "xip", "iso", "img", "toast", "cdr", "sparseimage",
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "webm", "mts", "m2ts", "mpg", "mpeg", "wmv", "flv", "hevc", "braw", "r3d",
    ]
    static let vmExtensions: Set<String> = [
        "vmdk", "vdi", "vhd", "vhdx", "qcow2", "hdd", "ipsw", "ova", "ovf", "utmdisk",
    ]

    /// Looks at the last extension (`archive.tar.gz` → `gz` → archive), case-insensitively. A name without an
    /// extension, a leading-dot name (`.zip`) or an unknown extension is `.other`.
    public static func classify(fileName: String) -> LargeFileKind {
        let name = (fileName as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        let ext = name[name.index(after: dot)...].lowercased()
        if archiveExtensions.contains(ext) { return .archive }
        if diskImageExtensions.contains(ext) { return .diskImageOrInstaller }
        if videoExtensions.contains(ext) { return .video }
        if vmExtensions.contains(ext) { return .vmImage }
        return .other
    }
}
