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
    private let fileExists: @Sendable (String) -> Bool

    public init(roots: StartupRoots, signatures: any CodeSignatureReading, loaded: LaunchctlLoadedState?, userID: uid_t,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.roots = roots
        self.signatures = signatures
        self.loaded = loaded
        self.userID = userID
        self.fileExists = fileExists
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
        if let program = parsed.program, program.hasPrefix("/") { programState = fileExists(program) ? .present : .missing }
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
