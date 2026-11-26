import Darwin
import Foundation

/// Capacity numbers for one mounted volume. Read-only metadata; no files are read.
public struct VolumeInfo: Sendable, Hashable, Codable {
    public let mountPath: String
    public let name: String?
    public let fileSystem: String?
    /// APFS: the whole container, shared by every volume in it.
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let availableForImportantUsage: Int64?
    public let availableForOpportunisticUsage: Int64?
    /// Bytes used by THIS volume only (`statfs`: `(f_blocks - f_bfree) * f_bsize`).
    public let usedBytesThisVolume: Int64?
    /// `st_dev` of the mount point; two paths on the same device share it.
    public let deviceID: Int64?
    public let isInternal: Bool?
    public let isEncrypted: Bool?
    public let isReadOnly: Bool?
    public let supportsClones: Bool?

    public init(
        mountPath: String, name: String? = nil, fileSystem: String? = nil,
        totalBytes: Int64, availableBytes: Int64,
        availableForImportantUsage: Int64? = nil, availableForOpportunisticUsage: Int64? = nil,
        usedBytesThisVolume: Int64? = nil, deviceID: Int64? = nil,
        isInternal: Bool? = nil, isEncrypted: Bool? = nil, isReadOnly: Bool? = nil, supportsClones: Bool? = nil
    ) {
        self.mountPath = mountPath
        self.name = name
        self.fileSystem = fileSystem
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsage = availableForImportantUsage
        self.availableForOpportunisticUsage = availableForOpportunisticUsage
        self.usedBytesThisVolume = usedBytesThisVolume
        self.deviceID = deviceID
        self.isInternal = isInternal
        self.isEncrypted = isEncrypted
        self.isReadOnly = isReadOnly
        self.supportsClones = supportsClones
    }

    /// An estimate of what macOS could free on demand (caches, purgeable files, some snapshots):
    /// `max(0, important - available)`. It moves from minute to minute and can be 0 even when Finder shows "purgeable".
    public var purgeableEstimate: Int64? {
        availableForImportantUsage.map { max(0, $0 - availableBytes) }
    }

    /// 0...1. Counts purgeable space as free (like System Settings does) when macOS reports it.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        let free = Double(availableForImportantUsage ?? availableBytes)
        return min(1, max(0, 1 - free / Double(totalBytes)))
    }
}

public enum VolumeInfoError: Error, Sendable, Equatable {
    case unavailable(path: String, reason: String)
}

public protocol VolumeInfoProviding: Sendable {
    func info(forPath path: String) async throws -> VolumeInfo
}

/// Reads capacity from URL resource keys plus `statfs`. Both calls are O(1) and block briefly, so they run off the caller's executor.
public struct LiveVolumeInfoProvider: VolumeInfoProviding {
    public init() {}

    public func info(forPath path: String) async throws -> VolumeInfo {
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) { try Self.read(path: path) }.value
    }

    static func read(path: String) throws -> VolumeInfo {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsEncryptedKey, .volumeIsReadOnlyKey,
            .volumeSupportsFileCloningKey,
        ]
        let v: URLResourceValues
        do { v = try url.resourceValues(forKeys: keys) } catch {
            throw VolumeInfoError.unavailable(path: path, reason: error.localizedDescription)
        }
        guard let total = v.volumeTotalCapacity, let available = v.volumeAvailableCapacity else {
            throw VolumeInfoError.unavailable(path: path, reason: "capacity keys missing")
        }
        var fs = statfs()
        var fsName: String?
        var used: Int64?
        if statfs(path, &fs) == 0 {
            fsName = withUnsafePointer(to: &fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            used = (Int64(fs.f_blocks) - Int64(fs.f_bfree)) * Int64(fs.f_bsize)
        }
        var st = stat()
        let dev: Int64? = stat(path, &st) == 0 ? Int64(st.st_dev) : nil
        return VolumeInfo(
            mountPath: path, name: v.volumeLocalizedName, fileSystem: fsName,
            totalBytes: Int64(total), availableBytes: Int64(available),
            availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage,
            availableForOpportunisticUsage: v.volumeAvailableCapacityForOpportunisticUsage,
            usedBytesThisVolume: used, deviceID: dev,
            isInternal: v.volumeIsInternal, isEncrypted: v.volumeIsEncrypted, isReadOnly: v.volumeIsReadOnly,
            supportsClones: v.volumeSupportsFileCloning)
    }
}
