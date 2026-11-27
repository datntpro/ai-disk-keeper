import Darwin
import Foundation

/// Incremental scan cache (T25): remembers the ``SizeReport`` of an item root and reuses it only while the file
/// system journal (FSEvents) can vouch that nothing at, inside, or above that root changed.
///
/// Why not directory mtimes: appending to a file in place changes neither its directory's nor any ancestor's mtime,
/// so a cached `newestModification` would go stale and a "newer than 1 day → keep" rule could come out Safe for data
/// being written right now. The journal reports every content write.
///
/// Safety rules (a stale cache must never make an item look smaller or safer than it is):
/// - An entry is valid only if NO changed path is equal to, inside, or an ancestor of its root, and the root's
///   `lstat` device / inode / mtime still match what was recorded BEFORE the walk.
/// - Anything the journal cannot vouch for (gaps, drops, wrap, mount events, timeout, different volume UUID,
///   different sizer options or app build, a corrupt or newer file) drops every entry.
/// - Only complete reports on the data volume are cached; reports with issues or skipped mounts never are.
/// - The cache only stores sizes and paths of the user's own items. It is never used by the cleanup engine, the
///   item validator or the disk indexer, and it never decides what is protected: the guard runs before sizing.
public actor SizeCache {
    public static let schemaVersion = 1
    public static let defaultCapacity = 50_000

    struct Entry: Codable, Sendable, Equatable {
        var path: String
        var report: SizeReport
        var rootDevice: Int64
        var rootInode: UInt64
        var rootMtimeSec: Int64
        var rootMtimeNsec: Int64
        var lastUsed: UInt64
    }

    struct Header: Codable, Sendable, Equatable {
        var schemaVersion: Int
        var volumeUUID: String
        var lastEventID: UInt64
        var sizerOptionsHash: String
        var appBuild: String
    }

    private struct FileBody: Codable { var header: Header; var entries: [Entry] }

    public let fileURL: URL?
    private let journal: any FSEventsJournaling
    private let capacity: Int
    private let appBuild: String
    private let dataDevice: dev_t?

    private var header: Header?
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var prepared = false
    private var clock: UInt64 = 0
    private var dirty = false
    /// Counters for tests and the benchmark.
    public private(set) var hits = 0
    public private(set) var misses = 0

    /// `fileURL == nil` keeps the cache in memory only (tests).
    public init(fileURL: URL?, journal: any FSEventsJournaling = LiveFSEventsJournal(),
                capacity: Int = SizeCache.defaultCapacity,
                appBuild: String = SizeCache.currentAppBuild, dataDevice: dev_t? = SizeCache.dataVolumeDevice()) {
        self.fileURL = fileURL
        self.journal = journal
        self.capacity = max(1, capacity)
        self.appBuild = appBuild
        self.dataDevice = dataDevice
    }

    public static func defaultFileURL(environment: PathEnvironment) -> URL {
        URL(fileURLWithPath: environment.applicationSupport + "/AIDiskKeeper/size-cache.json")
    }

    public static var currentAppBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
    }

    /// The device whose journal paths match our absolute paths (the Data volume on a modern macOS).
    public static func dataVolumeDevice() -> dev_t? {
        var st = stat()
        return stat("/System/Volumes/Data", &st) == 0 ? st.st_dev : nil
    }

    /// Only these options change what a report contains.
    public static func optionsHash(_ o: FileSizer.Options) -> String { "cv=\(o.crossVolumes);mi=\(o.maxRecordedIssues)" }

    public var count: Int { entries.count }

    // MARK: Scan lifecycle

    /// Call once at the start of a scan, before any walk. Captures the journal position FIRST, then asks what
    /// changed since the saved position, and drops every entry that cannot be vouched for.
    public func beginScan(options: FileSizer.Options) async {
        prepared = false
        loadIfNeeded()
        guard let device = dataDevice, let uuid = journal.volumeUUID(device: device) else {
            clearEntries()
            return
        }
        // Captured BEFORE the walk and before asking the journal: nothing after this point can be lost.
        let newID = journal.currentEventID()
        let optionsHash = Self.optionsHash(options)
        if let h = header, h.schemaVersion == Self.schemaVersion, h.volumeUUID == uuid,
           h.sizerOptionsHash == optionsHash, h.appBuild == appBuild, !entries.isEmpty {
            switch await journal.changedPaths(since: h.lastEventID, device: device) {
            case .invalidateAll:
                clearEntries()
            case .changed(let paths):
                dropEntries(affectedBy: paths)
            }
        } else {
            clearEntries()
        }
        header = Header(schemaVersion: Self.schemaVersion, volumeUUID: uuid, lastEventID: newID,
                        sizerOptionsHash: optionsHash, appBuild: appBuild)
        prepared = true
        dirty = true
    }

    /// Writes the cache (best effort; a failure only costs the next scan its speed).
    public func endScan() {
        evictIfNeeded()
        guard prepared, dirty, let fileURL, let header else { return }
        let body = FileBody(header: header, entries: Array(entries.values))
        guard let data = try? JSONEncoder().encode(body) else { return }
        if (try? Self.atomicWrite(data, to: fileURL)) != nil { dirty = false }
    }

    /// Forgets everything, in memory and on disk (Settings → Clear scan cache).
    public func clear() {
        clearEntries()
        header = nil
        prepared = false
        if let fileURL { remove(fileURL.path) }
    }

    // MARK: Lookup / store

    /// The cached report if (and only if) it is still valid right now.
    public func valid(_ url: URL) -> SizeReport? {
        guard prepared, let physical = Self.physicalPath(url) else { misses += 1; return nil }
        let key = Self.key(physical: physical)
        guard var entry = entries[key] else { misses += 1; return nil }
        guard let st = Self.lstat(url.path), Int64(st.st_dev) == entry.rootDevice, UInt64(st.st_ino) == entry.rootInode,
              Int64(st.st_mtimespec.tv_sec) == entry.rootMtimeSec, Int64(st.st_mtimespec.tv_nsec) == entry.rootMtimeNsec
        else {
            entries[key] = nil
            dirty = true
            misses += 1
            return nil
        }
        clock += 1
        entry.lastUsed = clock
        entries[key] = entry
        hits += 1
        return entry.report
    }

    /// What must be captured BEFORE the walk (a change during the walk then makes the next lookup miss).
    public struct RootStamp: Sendable {
        let device: Int64, inode: UInt64, sec: Int64, nsec: Int64
    }

    public func stamp(_ url: URL) -> RootStamp? {
        guard prepared, let st = Self.lstat(url.path), let dev = dataDevice, st.st_dev == dev else { return nil }
        return RootStamp(device: Int64(st.st_dev), inode: UInt64(st.st_ino),
                         sec: Int64(st.st_mtimespec.tv_sec), nsec: Int64(st.st_mtimespec.tv_nsec))
    }

    public func store(_ report: SizeReport, for url: URL, stamp: RootStamp?) {
        guard prepared, let stamp, report.issueCount == 0, report.skippedMountPoints.isEmpty,
              let physical = Self.physicalPath(url) else { return }
        clock += 1
        entries[Self.key(physical: physical)] = Entry(
            path: physical, report: report, rootDevice: stamp.device, rootInode: stamp.inode,
            rootMtimeSec: stamp.sec, rootMtimeNsec: stamp.nsec, lastUsed: clock)
        dirty = true
    }

    // MARK: Internals

    /// The journal reports physical paths, so the cache keys on the physical path: the parent directory is resolved
    /// (symlinks, `/tmp`), the leaf is not (the walk does not follow a symlink root either). nil = not cacheable.
    static func physicalPath(_ url: URL) -> String? {
        let path = url.path
        guard path.hasPrefix("/"), path.count > 1 else { return nil }
        let leaf = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolved = realpath(parent, nil) else { return nil }
        defer { free(resolved) }
        let base = String(cString: resolved)
        return base == "/" ? "/" + leaf : base + "/" + leaf
    }

    static func key(physical: String) -> String { "/" + PathCanonicalizer.key(physical).components.joined(separator: "/") }

    private static func lstat(_ path: String) -> stat? {
        var st = stat()
        return Darwin.lstat(path, &st) == 0 ? st : nil
    }

    private func clearEntries() {
        if !entries.isEmpty { dirty = true }
        entries = [:]
    }

    /// An entry survives only if no changed path is equal to, inside, or an ancestor of its root.
    private func dropEntries(affectedBy paths: [String]) {
        guard !paths.isEmpty else { return }
        var changed = Set<String>()        // the changed paths themselves
        var ancestors = Set<String>()      // every proper ancestor of a changed path
        for p in paths {
            let comps = PathCanonicalizer.key(p).components
            changed.insert("/" + comps.joined(separator: "/"))
            var prefix = ""
            for c in comps.dropLast() {
                prefix += "/" + c
                ancestors.insert(prefix)
            }
        }
        for key in Array(entries.keys) {
            var prefix = ""
            var hit = ancestors.contains(key)   // something inside the root changed
            if !hit {
                for c in key.split(separator: "/") {   // the root itself, or a directory above it, changed
                    prefix += "/" + c
                    if changed.contains(prefix) { hit = true; break }
                }
            }
            if hit { entries[key] = nil; dirty = true }
        }
    }

    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        let drop = entries.values.sorted { $0.lastUsed < $1.lastUsed }.prefix(entries.count - capacity)
        for e in drop { entries[Self.key(physical: e.path)] = nil }
        dirty = true
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let body = try? JSONDecoder().decode(FileBody.self, from: data),
              body.header.schemaVersion == Self.schemaVersion else { return }
        header = body.header
        entries = Dictionary(body.entries.map { (Self.key(physical: $0.path), $0) },
                             uniquingKeysWith: { a, _ in a })
        clock = entries.values.map(\.lastUsed).max() ?? 0
    }

    /// 0700 directory, 0600 temp file renamed into place (the `CareHistoryStore` pattern).
    private static func atomicWrite(_ data: Data, to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".size-cache-\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += n
                }
            }
            fsync(fd)
            close(fd)
            guard rename(tmp.path, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            close(fd)
            Darwin.remove(tmp.path)
            throw error
        }
    }

    private func remove(_ path: String) { Darwin.remove(path) }
}
