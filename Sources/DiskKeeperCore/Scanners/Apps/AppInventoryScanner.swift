import Darwin
import Foundation

public struct AppRoots: Sendable, Hashable {
    public var applications: String
    public var userApplications: String
    public var library: String

    public init(applications: String = "/Applications", userApplications: String, library: String) {
        self.applications = applications
        self.userApplications = userApplications
        self.library = library
    }

    public static func live(_ env: PathEnvironment) -> AppRoots {
        AppRoots(userApplications: env.home + "/Applications", library: env.home + "/Library")
    }
}

/// Lists installed `.app` bundles. Read-only: lstat, readdir, plist reads, signature info, sizing.
public struct AppInventoryScanner: Sendable {
    public let roots: AppRoots
    let signatures: any CodeSignatureReading
    let usage: any AppUsageProviding
    let runningApps: any RunningAppChecking
    let userID: uid_t
    let sizer: FileSizer
    let maxConcurrentSizing: Int
    let realPath: @Sendable (String) -> String?

    public init(roots: AppRoots, signatures: any CodeSignatureReading, usage: any AppUsageProviding,
                runningApps: any RunningAppChecking, userID: uid_t = getuid(), sizer: FileSizer = FileSizer(),
                maxConcurrentSizing: Int = 4) {
        self.init(roots: roots, signatures: signatures, usage: usage, runningApps: runningApps, userID: userID,
                  sizer: sizer, maxConcurrentSizing: maxConcurrentSizing, realPath: { AppBundleReader.resolvedPath($0) })
    }

    /// `realPath` is injectable so tests can pretend a bundle resolves into `/System`.
    init(roots: AppRoots, signatures: any CodeSignatureReading, usage: any AppUsageProviding,
         runningApps: any RunningAppChecking, userID: uid_t, sizer: FileSizer, maxConcurrentSizing: Int,
         realPath: @escaping @Sendable (String) -> String?) {
        self.roots = roots
        self.signatures = signatures
        self.usage = usage
        self.runningApps = runningApps
        self.userID = userID
        self.sizer = sizer
        self.maxConcurrentSizing = max(1, maxConcurrentSizing)
        self.realPath = realPath
    }

    private struct Candidate {
        let path: String
        let location: AppLocation
    }

    private struct Prepared {
        var app: InstalledApp
    }

    public func inventory() async throws -> AppInventory {
        var warnings: [ScanWarning] = []
        var scanned: [String] = []
        var candidates: [Candidate] = []

        // /Applications: depth 1, Utilities, and one level of vendor folders.
        if let names = list(roots.applications, &warnings) {
            scanned.append(roots.applications)
            for name in names {
                let path = roots.applications + "/" + name
                if Self.isAppName(name) {
                    candidates.append(Candidate(path: path, location: .applications))
                } else if let kind = AppBundleReader.entryKind(path), kind.isDirectory, !kind.isSymlink {
                    let isUtilities = PathCanonicalizer.fold(name) == "utilities"
                    if let inner = list(path, &warnings) {
                        for n in inner where Self.isAppName(n) {
                            candidates.append(Candidate(path: path + "/" + n,
                                                        location: isUtilities ? .applicationsUtilities : .applicationsNested))
                        }
                    }
                }
            }
        }
        if let names = list(roots.userApplications, &warnings) {
            scanned.append(roots.userApplications)
            for name in names where Self.isAppName(name) {
                candidates.append(Candidate(path: roots.userApplications + "/" + name, location: .userApplications))
            }
        }

        // Read metadata sequentially (cheap), then size under a limiter.
        var prepared: [Prepared] = []
        for c in candidates {
            try Task.checkCancellation()
            guard let kind = AppBundleReader.entryKind(c.path), kind.isDirectory else { continue }
            let infoPath = kind.isSymlink ? (AppBundleReader.resolvedPath(c.path) ?? c.path) : c.path
            let info: BundleInfo
            do {
                info = try AppBundleReader.read(bundlePath: infoPath)
            } catch AppBundleReadError.permissionDenied {
                warnings.append(ScanWarning(kind: .permissionDenied, path: c.path, message: "Couldn't read this app's details (permission denied)."))
                continue
            } catch AppBundleReadError.missingPlist {
                warnings.append(ScanWarning(kind: .scannerFailed, path: c.path, message: "Skipped: this app has no Info.plist."))
                continue
            } catch {
                warnings.append(ScanWarning(kind: .scannerFailed, path: c.path, message: "Skipped: this app's Info.plist is damaged."))
                continue
            }
            guard let bundleID = info.bundleID, RuleCleanup.isValidBundleID(bundleID) else {
                warnings.append(ScanWarning(kind: .other, path: c.path, message: "Skipped: this app has no valid bundle identifier."))
                continue
            }
            var source = signatures.source(ofBundleAt: infoPath)
            if source != .apple, AppBundleReader.hasAppStoreReceipt(bundlePath: infoPath) {
                source = .appStore(teamID: source.teamID)
            }
            // App Store Apple apps (Xcode, Pages, Keynote) fail `anchor apple`; treat Apple's own ids and team as Apple.
            if source != .apple, PathCanonicalizer.fold(bundleID).hasPrefix("com.apple.") || source.teamID == "59GAB85EFG" {
                source = .apple
            }
            let stem = String(((c.path as NSString).lastPathComponent as NSString).deletingPathExtension)
            let resolved = kind.isSymlink ? realPath(c.path) : nil
            let reason = Self.viewOnlyReason(source: source, path: c.path, resolved: resolved, isSymlink: kind.isSymlink,
                                             location: c.location, owner: kind.owner, userID: UInt32(userID))
            let app = InstalledApp(
                path: c.path, bundleID: bundleID, name: info.displayName ?? info.bundleName ?? stem,
                bundleName: info.bundleName, version: info.version, executableName: info.executable,
                location: c.location, source: source, ownerUID: kind.owner, isSymlink: kind.isSymlink,
                sizeAllocated: 0, sizeLogical: 0, fileCount: 0, lastUsed: usage.lastUsedDate(ofBundleAt: infoPath),
                isRunning: runningApps.isRunning(bundleID: bundleID), viewOnlyReason: reason)
            prepared.append(Prepared(app: app))
        }

        let reports = try await sizeAll(prepared.map(\.app))
        var apps: [InstalledApp] = []
        for (i, p) in prepared.enumerated() {
            var a = p.app
            if let report = reports[i] {
                a = InstalledApp(
                    path: a.path, bundleID: a.bundleID, name: a.name, bundleName: a.bundleName, version: a.version,
                    executableName: a.executableName, location: a.location, source: a.source, ownerUID: a.ownerUID,
                    isSymlink: a.isSymlink, sizeAllocated: report.allocatedBytes, sizeLogical: report.logicalBytes,
                    fileCount: report.fileCount, lastUsed: a.lastUsed, isRunning: a.isRunning, viewOnlyReason: a.viewOnlyReason)
                if report.issueCount > 0 {
                    warnings.append(ScanWarning(kind: .permissionDenied, path: a.path,
                                                message: "Some files inside this app couldn't be read, so its size may be too low."))
                }
            }
            apps.append(a)
        }
        apps.sort {
            if $0.sizeAllocated != $1.sizeAllocated { return $0.sizeAllocated > $1.sizeAllocated }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.path < $1.path
        }
        return AppInventory(apps: apps, warnings: warnings, scannedRoots: scanned)
    }

    static func viewOnlyReason(source: AppSource, path: String, resolved: String?, isSymlink: Bool,
                               location: AppLocation, owner: UInt32, userID: UInt32) -> InstalledApp.ViewOnlyReason? {
        if source == .apple { return .apple }
        func underSystem(_ p: String) -> Bool { p == "/System" || p.hasPrefix("/System/") }
        if underSystem(path) || (resolved.map(underSystem) ?? false) { return .systemVolume }
        if isSymlink { return .symlink }
        if !location.isTopLevel { return .notTopLevel }
        if owner != userID { return .notOwnedByUser }
        return nil
    }

    static func isAppName(_ name: String) -> Bool {
        PathCanonicalizer.fold(name).hasSuffix(".app") && name.count > 4
    }

    private func list(_ dir: String, _ warnings: inout [ScanWarning]) -> [String]? {
        switch DirectoryLister.names(at: dir) {
        case .success(let names): return names
        case .failure(let e):
            switch e.code {
            case .ENOENT, .ENOTDIR: break
            case .EPERM: warnings.append(ScanWarning(kind: .needsFullDiskAccess, path: dir, message: "Couldn't list this folder. Full Disk Access may be needed."))
            default: warnings.append(ScanWarning(kind: .permissionDenied, path: dir, message: "Couldn't list this folder (permission denied)."))
            }
            return nil
        }
    }

    /// Sizes each bundle (symlinks are not followed: the sizer lstat's the root).
    private func sizeAll(_ apps: [InstalledApp]) async throws -> [SizeReport?] {
        let limiter = AsyncLimiter(limit: maxConcurrentSizing)
        let sizer = self.sizer
        return try await withThrowingTaskGroup(of: (Int, SizeReport?).self) { group in
            for (i, app) in apps.enumerated() {
                group.addTask {
                    try await limiter.acquire()
                    do {
                        let r = try await sizer.size(of: URL(fileURLWithPath: app.path))
                        await limiter.release()
                        return (i, r)
                    } catch is CancellationError {
                        await limiter.release()
                        throw CancellationError()
                    } catch {
                        await limiter.release()
                        return (i, nil)
                    }
                }
            }
            var out = [SizeReport?](repeating: nil, count: apps.count)
            for try await (i, r) in group { out[i] = r }
            return out
        }
    }
}
