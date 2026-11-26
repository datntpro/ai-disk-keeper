import Darwin
import Foundation

/// The two places an app may be uninstalled from. NOT `AppRoots` (which also lists `/Library` for leftovers).
public struct ApplicationRoots: Sendable, Hashable {
    /// Lexical, no trailing slash. Index 0 is the system-wide root (the only one the guard waiver may apply to).
    public let roots: [String]

    public init(roots: [String]) { self.roots = roots }

    public static func live(_ env: PathEnvironment) -> ApplicationRoots {
        ApplicationRoots(roots: ["/Applications", PathNormalization.lexical(env.home + "/Applications")])
    }
}

public enum AppBundleRefusal: String, Codable, Sendable, CaseIterable {
    case invalidPath, notTopLevel, insideBundle, rootItself, notAnAppBundle, symlink, resolvedElsewhere,
         appleOrSystem, signatureUnreadable, bundleIDMismatch, missingInfoPlist, permanentDelete,
         notApplicationMethod
}

/// Plan-time snapshot of the bundle. Part of the plan, so tampering is `planModified`; compared at execute time.
public struct AppBundleFingerprint: Codable, Sendable, Hashable {
    public let bundleDevice: Int32
    public let bundleInode: UInt64
    public let infoPlistDevice: Int32
    public let infoPlistInode: UInt64
    public let infoPlistSize: Int64
    public let infoPlistModified: Date
    public let bundleID: String
    public let ownerUID: UInt32

    public init(bundleDevice: Int32, bundleInode: UInt64, infoPlistDevice: Int32, infoPlistInode: UInt64,
                infoPlistSize: Int64, infoPlistModified: Date, bundleID: String, ownerUID: UInt32) {
        self.bundleDevice = bundleDevice; self.bundleInode = bundleInode
        self.infoPlistDevice = infoPlistDevice; self.infoPlistInode = infoPlistInode
        self.infoPlistSize = infoPlistSize; self.infoPlistModified = infoPlistModified
        self.bundleID = bundleID; self.ownerUID = ownerUID
    }
}

/// The single exception to "everything outside `~` is protected" (safety invariant 15). Consulted only for
/// `.trashApplication`. It can waive exactly one guard verdict and nothing else. See docs/protected-paths.md.
public struct ApplicationBundlePolicy: Sendable {
    public let roots: ApplicationRoots
    let userID: uid_t
    let probe: any AppBundleProbing

    public init(roots: ApplicationRoots, userID: uid_t, probe: any AppBundleProbing) {
        self.roots = roots
        self.userID = userID
        self.probe = probe
    }

    // MARK: Lexical (no syscalls)

    /// Rows 3, 4, 5, 11 (name part), 14, plus invalid input.
    public func lexicalRefusal(_ path: String) -> AppBundleRefusal? {
        Self.lexicalRefusal(path, roots: roots)
    }

    static func lexicalRefusal(_ path: String, roots: ApplicationRoots) -> AppBundleRefusal? {
        guard PathNormalization.isAbsolute(path), !PathNormalization.containsNUL(path),
              !PathNormalization.containsParentReference(path),
              PathNormalization.lexical(path) == path, path != "/",
              !path.hasSuffix("/") else { return .invalidPath }
        let comps = PathNormalization.components(path).map(String.init)
        guard let name = comps.last else { return .invalidPath }
        let key = PathCanonicalizer.key(path)
        if roots.roots.contains(where: { PathCanonicalizer.key($0) == key }) { return .rootItself }
        // Checked before top-level, so `/Applications/X.app/Contents/Y.app` reports `insideBundle`.
        if comps.dropLast().contains(where: isAppName) { return .insideBundle }
        let parentKey = PathCanonicalizer.key((path as NSString).deletingLastPathComponent)
        guard roots.roots.contains(where: { PathCanonicalizer.key($0) == parentKey }) else { return .notTopLevel }
        guard isAppName(name), name.utf8.count > 4 else { return .notAnAppBundle }
        return nil
    }

    /// Apple's team ids for Apple-published Mac App Store apps.
    static let appleTeamIDs: Set<String> = ["59GAB85EFG", "74J34U3R6X"]

    public static func isAppleIdentity(bundleID: String, teamID: String?) -> Bool {
        if PathCanonicalizer.fold(bundleID).hasPrefix("com.apple.") { return true }
        if let teamID, appleTeamIDs.contains(teamID.uppercased()) { return true }
        return false
    }

    private static func isAppName(_ s: String) -> Bool { s.lowercased().hasSuffix(".app") }

    /// The ONLY guard waiver: `systemLocation` for a path whose lexical parent is exactly the system
    /// `Applications` root and which passes every lexical check.
    static func waives(_ denial: PathDenial, path: String, roots: ApplicationRoots) -> Bool {
        guard denial.reason == .systemLocation, let systemRoot = roots.roots.first,
              lexicalRefusal(path, roots: roots) == nil else { return false }
        return PathCanonicalizer.key((path as NSString).deletingLastPathComponent) == PathCanonicalizer.key(systemRoot)
    }

    // MARK: Full evaluation

    /// Checks 0-15 of the plan. Returns the blockers (empty = allowed) and the fingerprint to bind into the
    /// plan. Collects every applicable blocker but stops after the first filesystem failure.
    public func evaluate(_ item: ScanItem, action: CleanupAction, expected: AppBundleFingerprint?,
                         pathGuard: ProtectedPaths, runningApps: any RunningAppChecking)
        -> (blockers: [CleanupBlocker], fingerprint: AppBundleFingerprint?) {
        var out: [CleanupBlocker] = []
        func add(_ b: CleanupBlocker) { if !out.contains(b) { out.append(b) } }

        guard case .trashApplication(let bundleID) = item.cleanupMethod else {
            return ([.appBundleRefused(.notApplicationMethod)], nil)
        }
        if action != .trash { add(.appBundleRefused(.permanentDelete)) }

        let path = item.path
        if let refusal = lexicalRefusal(path) { add(.appBundleRefused(refusal)); return (out, nil) }

        guard let st = probe.lstat(path) else { add(.missing); return (out, nil) }
        if st.isSymlink { add(.appBundleRefused(.symlink)); return (out, nil) }
        if !st.isDirectory { add(.appBundleRefused(.notAnAppBundle)); return (out, nil) }

        // Whole-path resolution, so a symlinked parent or a swapped component can't redirect the move.
        let lexicalKey = PathCanonicalizer.key(path)
        guard let resolved = probe.realpath(path) else { add(.appBundleRefused(.resolvedElsewhere)); return (out, nil) }
        if PathCanonicalizer.key(resolved) != lexicalKey {
            add(.appBundleRefused(.resolvedElsewhere))
            let parent = (path as NSString).deletingLastPathComponent
            if let rp = probe.realpath(parent), PathCanonicalizer.key(rp) != PathCanonicalizer.key(parent) {
                add(.symlinkInParentChain(resolvedParent: rp))
            }
            return (out, nil)
        }

        // Sealed system volume (nil = unknown, fail closed).
        if PathCanonicalizer.key(resolved).components.first == "system" || probe.isOnSealedSystemVolume(path) != false {
            add(.appBundleRefused(.appleOrSystem))
        }
        let source = probe.signatureSource(path)
        switch source {
        case .apple: add(.appBundleRefused(.appleOrSystem))
        case .unknown: add(.appBundleRefused(.signatureUnreadable))
        case .developerID, .appStore, .unsigned: break
        }
        // Apple's own App Store apps (Xcode, Pages, ...) are signed by "Apple Mac OS Application Signing",
        // not `anchor apple`: refuse any Apple team id or `com.apple.` bundle id, whoever owns the bundle.
        if Self.isAppleIdentity(bundleID: bundleID, teamID: source.teamID) { add(.appBundleRefused(.appleOrSystem)) }

        if st.uid != userID { add(.requiresAdmin(bundleID: bundleID)) }

        var fingerprint: AppBundleFingerprint?
        switch probe.readInfoPlist(bundle: path) {
        case .ok(let id, let plist):
            if id != bundleID { add(.appBundleRefused(.bundleIDMismatch)) }
            if Self.isAppleIdentity(bundleID: id, teamID: nil) { add(.appBundleRefused(.appleOrSystem)) }
            fingerprint = AppBundleFingerprint(
                bundleDevice: st.device, bundleInode: st.inode, infoPlistDevice: plist.device,
                infoPlistInode: plist.inode, infoPlistSize: plist.size, infoPlistModified: plist.modified,
                bundleID: id, ownerUID: st.uid)
        case .missing, .unreadable, .notRegular:
            add(.appBundleRefused(.missingInfoPlist))
        }

        switch runningApps.isRunning(bundleID: bundleID) {
        case .some(true): add(.appRunning(bundleID: bundleID))
        case .none: add(.appStateUnknown(bundleID: bundleID))
        case .some(false): break
        }
        switch runningApps.isAnyProcessRunning(insideBundleAt: path) {
        case .some(true): add(.appRunning(bundleID: bundleID))
        case .none: add(.appStateUnknown(bundleID: bundleID))
        case .some(false): break
        }

        if let denial = pathGuard.check(path).denial {
            if !Self.waives(denial, path: path, roots: roots) {
                add(.protectedPath(denial.reason, message: denial.message, pattern: denial.matchedPattern,
                                   whyID: denial.whyID))
            } else if let pattern = pathGuard.anchoredPatternDenial(path) {
                // The waiver lifts `systemLocation` only; a protect pattern on the bundle always wins.
                add(.protectedPath(pattern.reason, message: pattern.message, pattern: pattern.matchedPattern,
                                   whyID: pattern.whyID))
            }
        }

        if let expected, let fingerprint, expected != fingerprint { add(.identityChanged) }
        return (out, fingerprint)
    }
}
