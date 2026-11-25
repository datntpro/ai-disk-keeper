import Darwin
import Foundation

/// Scratch directory for filesystem tests. Never touches anything outside its own root.
final class TemporaryDirectory {
    let url: URL
    private var chmodded: [String] = []

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskKeeperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // macOS /var is a symlink to /private/var; resolve so paths compare predictably.
        guard let resolved = realpath(base.path, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(resolved) }
        url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func path(_ rel: String) -> String { url.appendingPathComponent(rel).path }

    @discardableResult
    func file(_ relPath: String, bytes: Int = 0, contents: Data? = nil) throws -> URL {
        let u = url.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = contents ?? Data(repeating: 0x41, count: bytes)
        guard FileManager.default.createFile(atPath: u.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return u
    }

    @discardableResult
    func dir(_ relPath: String) throws -> URL {
        let u = url.appendingPathComponent(relPath, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func symlink(_ relPath: String, to destination: String) throws -> URL {
        let u = url.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard Darwin.symlink(destination, u.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return u
    }

    @discardableResult
    func hardlink(_ relPath: String, to existingRelPath: String) throws -> URL {
        let u = url.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard link(path(existingRelPath), u.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return u
    }

    func setMTime(_ relPath: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relPath))
    }

    func chmod(_ relPath: String, _ mode: mode_t) throws {
        guard Darwin.chmod(path(relPath), mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        chmodded.append(relPath)
    }

    func cleanup() {
        for rel in chmodded { _ = Darwin.chmod(path(rel), 0o755) }
        chmodded.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    deinit { cleanup() }
}
