import Darwin
import Foundation
import Security

/// A filesystem object's identity, as `lstat`/`fstat` report it.
public struct FileStat: Sendable, Hashable {
    public let device: Int32
    public let inode: UInt64
    public let mode: mode_t
    public let uid: UInt32
    public let size: Int64
    public let modified: Date

    public init(device: Int32, inode: UInt64, mode: mode_t, uid: UInt32, size: Int64, modified: Date) {
        self.device = device; self.inode = inode; self.mode = mode
        self.uid = uid; self.size = size; self.modified = modified
    }

    public var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }
    public var isSymlink: Bool { (mode & S_IFMT) == S_IFLNK }
    public var isRegular: Bool { (mode & S_IFMT) == S_IFREG }

    init(_ st: stat) {
        self.init(device: Int32(truncatingIfNeeded: st.st_dev), inode: UInt64(st.st_ino), mode: st.st_mode,
                  uid: UInt32(st.st_uid), size: Int64(st.st_size),
                  modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                                 + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9))
    }
}

public enum InfoPlistRead: Sendable, Hashable {
    case ok(bundleID: String, FileStat)
    case missing
    /// Unparsable, no `CFBundleIdentifier`, or larger than the 1 MiB cap.
    case unreadable
    /// A symlink or another non-regular file.
    case notRegular
}

/// Every syscall `ApplicationBundlePolicy` makes. Faked in tests.
public protocol AppBundleProbing: Sendable {
    func lstat(_ path: String) -> FileStat?
    func realpath(_ path: String) -> String?
    func readInfoPlist(bundle: String) -> InfoPlistRead
    /// nil = could not tell. The policy treats that as true (fail closed).
    func isOnSealedSystemVolume(_ path: String) -> Bool?
    func signatureSource(_ path: String) -> AppSource
}

/// The real thing. Read-only.
public struct LiveAppBundleProbe: AppBundleProbing {
    public static let maxInfoPlistBytes = 1 << 20

    public init() {}

    public func lstat(_ path: String) -> FileStat? {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return FileStat(st)
    }

    public func realpath(_ path: String) -> String? {
        guard let r = Darwin.realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    public func readInfoPlist(bundle: String) -> InfoPlistRead {
        // `O_NOFOLLOW` only covers the last component, so `Contents` is lstat-checked separately.
        guard let contents = lstat(bundle + "/Contents"), contents.isDirectory else { return .missing }
        let path = bundle + "/Contents/Info.plist"
        guard let before = lstat(path) else { return .missing }
        guard before.isRegular else { return .notRegular }
        guard before.size <= Int64(Self.maxInfoPlistBytes) else { return .unreadable }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ELOOP ? .notRegular : .unreadable }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              Int64(st.st_size) <= Int64(Self.maxInfoPlistBytes),
              UInt64(st.st_ino) == before.inode else { return .unreadable }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return .unreadable }
            if n == 0 { break }
            data.append(buffer, count: n)
            if data.count > Self.maxInfoPlistBytes { return .unreadable }
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty else { return .unreadable }
        return .ok(bundleID: id, FileStat(st))
    }

    /// Sealed system snapshot or any read-only/snapshot mount. `/` itself is the sealed snapshot.
    public func isOnSealedSystemVolume(_ path: String) -> Bool? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mount = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let flags = fs.f_flags
        return (flags & UInt32(MNT_SNAPSHOT)) != 0 || (flags & UInt32(MNT_RDONLY)) != 0 || mount == "/"
    }

    public func signatureSource(_ path: String) -> AppSource {
        SecStaticCodeSignatureReader().source(ofBundleAt: path)
    }
}
