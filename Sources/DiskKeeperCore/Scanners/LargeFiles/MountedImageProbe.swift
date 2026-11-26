import Darwin
import Foundation
import IOKit

/// The disk images that are attached right now. A mounted image is in use: deleting it would pull a volume out from
/// under the user, so Large & Old shows it as Keep ("eject it first"). Read-only: nothing is detached or touched.
public protocol MountedImageProbing: Sendable {
    /// Backing-image paths, normalised with ``MountedImagePaths/key(_:)``. Throws when nobody could answer.
    func mountedImagePaths() async throws -> Set<String>
}

public enum MountedImagePaths {
    /// realpath (symlinks, `..`, `/private` aliases resolved), then case-folded: APFS volumes are case-insensitive by default.
    public static func key(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(path, &buffer) != nil ? String(cString: buffer) : (path as NSString).standardizingPath
        return resolved.lowercased()
    }

    /// An IORegistry/hdiutil `image-path` value: a `file://` URL (percent-encoded) or a plain path, maybe NUL-terminated.
    static func path(fromRaw raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }
}

/// IORegistry first (`IOHDIXHDDrive*` → `image-path`: no process, no timeout); `hdiutil info -plist` when the registry
/// can't be read. Never runs `hdiutil detach`.
public struct SystemMountedImageProbe: MountedImageProbing {
    public typealias Registry = @Sendable () -> Set<String>?

    private let registry: Registry
    private let hdiutil: URL
    private let runner: ProcessRunner
    private let timeout: Duration

    public init(registry: @escaping Registry = { SystemMountedImageProbe.readRegistry() },
                hdiutil: URL = URL(fileURLWithPath: "/usr/bin/hdiutil"),
                runner: ProcessRunner = ProcessRunner(maxOutputBytes: 4 << 20), timeout: Duration = .seconds(5)) {
        self.registry = registry
        self.hdiutil = hdiutil
        self.runner = runner
        self.timeout = timeout
    }

    /// The only hdiutil call: `info -plist` lists, never changes anything.
    static let hdiutilArguments = ["info", "-plist"]

    public func mountedImagePaths() async throws -> Set<String> {
        if let fromRegistry = registry() { return fromRegistry }
        let r = try await runner.run(executable: hdiutil, arguments: Self.hdiutilArguments,
                                     environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                                     currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
        guard r.exitStatus == 0 else { throw MountedImageProbeError.hdiutilFailed(status: r.exitStatus) }
        return try Self.parse(plist: r.stdout)
    }

    /// `hdiutil info -plist`: `{ images = [ { "image-path" = …; } ] }`.
    static func parse(plist data: Data) throws -> Set<String> {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { throw MountedImageProbeError.unreadable }
        return Set(images.compactMap { ($0["image-path"] as? String).flatMap(MountedImagePaths.path(fromRaw:)) }
            .map(MountedImagePaths.key))
    }

    /// `nil` when the registry could not be matched at all (empty is a valid answer: nothing attached).
    public static func readRegistry() -> Set<String>? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHDIXHDDrive"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var out = Set<String>()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let value = IORegistryEntrySearchCFProperty(
                entry, kIOServicePlane, "image-path" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            let raw: String?
            if let data = value as? Data { raw = String(decoding: data, as: UTF8.self) } else { raw = value as? String }
            if let raw, let p = MountedImagePaths.path(fromRaw: raw) { out.insert(MountedImagePaths.key(p)) }
        }
        return out
    }
}

public enum MountedImageProbeError: Error, Sendable, Equatable {
    case hdiutilFailed(status: Int32)
    case unreadable
}
