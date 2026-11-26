import Darwin
import Foundation

/// Lists launch agents and daemons. Read-only: it parses plists and asks the system which are loaded.
/// Only a user agent whose program is gone is ever offered for removal (and only `scan` hands that to cleanup).
public struct StartupItemScanner: Scanner {
    public let id = "startup-items"

    private let roots: StartupRoots
    private let signatures: any CodeSignatureReading
    private let loaded: LaunchctlLoadedState?
    private let userID: uid_t
    private let probe: @Sendable (String) -> ProgramProbe

    public init(roots: StartupRoots, signatures: any CodeSignatureReading, loaded: LaunchctlLoadedState?, userID: uid_t,
                probe: @escaping @Sendable (String) -> ProgramProbe = { StartupItemScanner.probe($0) }) {
        self.roots = roots
        self.signatures = signatures
        self.loaded = loaded
        self.userID = userID
        self.probe = probe
    }

    /// Every item, for the screen. Never throws except `CancellationError`.
    public func inventory() async throws -> StartupInventory {
        var warnings: [ScanWarning] = []
        var states: [String: StartupItem.LoadState]?
        if let loaded {
            if case .loaded(let found) = try await loaded.load(userID: userID) {
                states = found
            } else {
                warnings.append(ScanWarning(kind: .other, message: "Couldn't read which items are loaded.",
                                            code: .scannerFailed(scannerID: id)))
            }
        }
        var items: [StartupItem] = []
        let domains: [(StartupItem.Domain, String)] = [
            (.userAgent, roots.userAgents), (.systemAgent, roots.systemAgents), (.systemDaemon, roots.systemDaemons),
        ]
        for (domain, root) in domains {
            try Task.checkCancellation()
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: root)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                continue
            } catch {
                warnings.append(ScanWarning(kind: .permissionDenied, path: root, message: "Couldn't read \(root).",
                                            code: .pathError(errno: EACCES)))
                continue
            }
            for name in names.sorted() where name.hasSuffix(".plist") && !name.hasPrefix(".") {
                try Task.checkCancellation()
                if let item = makeItem(path: root + "/" + name, domain: domain, states: states) { items.append(item) }
            }
        }
        return StartupInventory(items: items, warnings: warnings)
    }

    /// Emits ONLY removable user agents (for Care Scan), and only those the guard allows.
    public func scan(context: ScanContext, sink: ScanSink) async throws {
        let inventory = try await inventory()
        for warning in inventory.warnings { await sink.warning(warning) }
        for item in inventory.items where item.isRemovable {
            try Task.checkCancellation()
            guard context.pathGuard.check(item.plistPath).isAllowed else { continue }
            await sink.item(item.makeScanItem())
        }
    }

    // MARK: Building one item

    private func makeItem(path: String, domain: StartupItem.Domain,
                          states: [String: StartupItem.LoadState]?) -> StartupItem? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let kind = st.st_mode & S_IFMT
        if kind == S_IFDIR { return nil }
        let isSymlink = kind == S_IFLNK
        let parsed = LaunchPlistReader.read(path: path)

        var programState = StartupItem.ProgramState.unresolvable
        // A BundleProgram (SMAppService) item is managed by its app: never broken, whatever else the plist says.
        if !parsed.isBundleManaged, let program = parsed.program, program.hasPrefix("/") {
            switch probe(program) {
            case .exists: programState = .present
            case .missing: programState = .missing
            case .uncertain: programState = .unresolvable
            }
        }
        var signer: AppSource?
        if programState == .present, let program = parsed.program { signer = signatures.source(ofBundleAt: Self.signedPath(program)) }

        var loadState = StartupItem.LoadState.unknown
        if let states, domain != .systemDaemon, let label = parsed.label { loadState = states[label] ?? .notLoaded }

        return StartupItem(
            plistPath: PathNormalization.lexical(path), label: parsed.label, program: parsed.program,
            arguments: parsed.arguments, schedules: parsed.schedules, domain: domain, programState: programState,
            signer: signer, loadState: loadState, isHomebrewService: parsed.label?.hasPrefix("homebrew.mxcl.") == true,
            parseError: parsed.parseError, ownerUID: st.st_uid, isSymlink: isSymlink, ownedByUser: st.st_uid == userID,
            lastModified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
            allocatedBytes: Int64(st.st_blocks) * 512, logicalBytes: Int64(st.st_size), isBundleManaged: parsed.isBundleManaged)
    }

    /// What a program path check found. Only `missing` can make an item "broken"; anything uncertain is not.
    public enum ProgramProbe: Sendable, Equatable { case exists, missing, uncertain }

    /// `missing` only when `stat` says ENOENT/ENOTDIR and, for a path under `mountParent/<name>/` (default
    /// `/Volumes`), `<name>` is a mounted volume. Unmounted disks, permission errors (EACCES, EPERM) and any
    /// other error are `uncertain`: the program may well exist, we just can't see it.
    public static func probe(_ path: String, mountParent: String = "/Volumes") -> ProgramProbe {
        var st = stat()
        if stat(path, &st) == 0 { return .exists }
        guard errno == ENOENT || errno == ENOTDIR else { return .uncertain }
        let prefix = mountParent.hasSuffix("/") ? mountParent : mountParent + "/"
        guard path.hasPrefix(prefix) else { return .missing }
        guard let name = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first else { return .uncertain }
        return isMountedVolume(prefix + name, parent: mountParent) ? .missing : .uncertain
    }

    /// A volume mount: a different device than its parent folder, or a link to the root volume.
    static func isMountedVolume(_ path: String, parent: String) -> Bool {
        var volume = stat(), container = stat()
        guard stat(path, &volume) == 0, stat(parent, &container) == 0 else { return false }
        guard (volume.st_mode & S_IFMT) == S_IFDIR else { return false }
        return volume.st_dev != container.st_dev || volume.st_ino == 2
    }

    /// The enclosing `.app` if the program is inside one, else the program itself.
    static func signedPath(_ program: String) -> String {
        var path = ""
        for part in program.split(separator: "/", omittingEmptySubsequences: true) {
            path += "/" + part
            if part.hasSuffix(".app") { return path }
        }
        return program
    }
}
