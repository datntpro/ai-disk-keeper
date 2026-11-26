import CryptoKit
import Darwin
import Foundation
@testable import DiskKeeperCore

struct FixtureEntry: Equatable {
    enum Kind: Equatable { case file, directory, symlink, other }
    let kind: Kind
    let size: Int64
    let mtimeSeconds: Int
    let mtimeNanos: Int
    /// sha256 hex for regular files, link target for symlinks, "" otherwise.
    let content: String
}

/// A fake home + temp dir inside one scratch directory. Paths starting with `$TMP/` are relative to
/// `tempDir`; all others are relative to `home`. Nothing here ever touches the real home.
final class FixtureHome {
    let tmp: TemporaryDirectory
    let home: String
    let tempDir: String
    var env: PathEnvironment

    init() throws {
        tmp = try TemporaryDirectory()
        home = tmp.path("home")
        tempDir = tmp.path("tmp")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        env = PathEnvironment(home: home, temporaryDirectory: tempDir, variables: [:])
    }

    func abs(_ relToHome: String) -> String {
        precondition(!relToHome.hasPrefix("/") && !PathNormalization.containsParentReference(relToHome),
                     "fixture paths must be relative and free of '..': \(relToHome)")
        return relToHome.hasPrefix("$TMP/") ? tempDir + "/" + relToHome.dropFirst(5) : home + "/" + relToHome
    }

    /// Set `modified` AFTER creating children: creating a child bumps the directory's mtime.
    @discardableResult
    func file(_ relToHome: String, bytes: Int = 1, modified: Date? = nil) throws -> String {
        let path = abs(relToHome)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try touch(path, modified)
        return path
    }

    @discardableResult
    func dir(_ relToHome: String, modified: Date? = nil) throws -> String {
        let path = abs(relToHome)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try touch(path, modified)
        return path
    }

    @discardableResult
    func symlink(_ relToHome: String, to dest: String) throws -> String {
        let path = abs(relToHome)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard Darwin.symlink(dest, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return path
    }

    private func touch(_ path: String, _ date: Date?) throws {
        guard let date else { return }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// Every entry under the scratch directory: rel path → (type, size, mtime, sha256 or link target).
    func snapshot() throws -> [String: FixtureEntry] {
        var out: [String: FixtureEntry] = [:]
        func walk(_ dir: String, _ rel: String) {
            guard let dp = opendir(dir) else { return }
            defer { closedir(dp) }
            while let entry = readdir(dp) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let path = dir + "/" + name
                let r = rel.isEmpty ? name : rel + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let kind: FixtureEntry.Kind
                var content = ""
                switch st.st_mode & S_IFMT {
                case S_IFDIR: kind = .directory
                case S_IFLNK:
                    kind = .symlink
                    content = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
                case S_IFREG:
                    kind = .file
                    if let d = FileManager.default.contents(atPath: path) {
                        content = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
                    }
                default: kind = .other
                }
                out[r] = FixtureEntry(kind: kind, size: Int64(st.st_size), mtimeSeconds: Int(st.st_mtimespec.tv_sec),
                                      mtimeNanos: Int(st.st_mtimespec.tv_nsec), content: content)
                if kind == .directory { walk(path, r) }
            }
        }
        walk(tmp.url.path, "")
        return out
    }
}
