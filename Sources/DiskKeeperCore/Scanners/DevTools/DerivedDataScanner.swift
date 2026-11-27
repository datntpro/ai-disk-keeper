import Darwin
import Foundation

/// Why a DerivedData folder got its tier. The English text is the item's `explanation`; the UI maps the
/// variant back (`DerivedDataVariant.of(_:)`) to a translated string, so keep the two in step.
public enum DerivedDataVariant: String, Sendable, CaseIterable {
    case active, projectGone, projectGoneRecent, projectExists, unreadable

    public var explanation: String {
        switch self {
        case .active:
            "Regenerable: build output for an Xcode project. It changed in the last day, so a build or the editor may be using it. Kept."
        case .projectGone:
            "Regenerable: build output, indexes and logs for an Xcode project that no longer exists on this Mac. "
                + "Nothing will ask for it again, and Xcode rebuilds it if the project comes back."
        case .projectGoneRecent:
            "Regenerable: build output for an Xcode project that was removed or moved less than a week ago. "
                + "Xcode rebuilds it if the project comes back, so check that you do not still need the project first."
        case .projectExists:
            "Regenerable: build output, indexes and logs for an Xcode project that still exists. Xcode rebuilds it, "
                + "so the next build of that project is slower and its indexing starts again."
        case .unreadable:
            "Regenerable: build output for an Xcode project, but Disk Keeper couldn't read the project path from this folder, "
                + "so it can't tell whether the project still exists. Xcode rebuilds it on the next build."
        }
    }

    public static func of(_ item: ScanItem) -> DerivedDataVariant? {
        guard item.ruleID == DerivedDataScanner.ruleID else { return nil }
        return allCases.first { $0.explanation == item.explanation }
    }
}

/// Offers each project's folder in Xcode's global DerivedData. Read-only. The only file it reads inside a
/// folder is `info.plist` (≤ 64 KiB), for the project path; everything else is sized, never opened.
/// Cleanup is the ordinary Trash path. `ModuleCache.noindex` is a rule (`build-caches.xcode-modulecache`).
public struct DerivedDataScanner: Scanner {
    public static let ruleID = "build-caches.xcode-deriveddata"
    public static let toolID: ToolID = "build-caches"
    public static let maxPlistBytes = 64 * 1024
    static let moduleCacheName = "ModuleCache.noindex"

    public let id = "build-caches.deriveddata"
    private let root: String
    private let mountsRoot: String

    public init(root: String, mountsRoot: String = "/Volumes") {
        self.root = root
        self.mountsRoot = mountsRoot
    }

    public static func live(environment: PathEnvironment) -> DerivedDataScanner {
        DerivedDataScanner(root: environment.home + "/Library/Developer/Xcode/DerivedData")
    }

    public func scan(context: ScanContext, sink: ScanSink) async throws {
        var st = stat()
        // A symlinked DerivedData may point anywhere (another volume, a shared folder): leave it alone.
        guard lstat(root, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == context.userID else { return }
        for name in Self.childNames(of: root).sorted() {
            try Task.checkCancellation()
            guard !name.hasPrefix("."), name.lowercased() != Self.moduleCacheName.lowercased() else { continue }
            let path = root + "/" + name
            var cs = stat()
            guard lstat(path, &cs) == 0, (cs.st_mode & S_IFMT) == S_IFDIR, cs.st_uid == context.userID,
                  context.pathGuard.check(path).isAllowed,
                  let size = try? await context.size(URL(fileURLWithPath: path)) else { continue }
            let workspace = Self.workspacePath(inFolder: path)
            let (tier, variant) = classify(workspace: workspace, newest: size.newestModification, now: context.now)
            let project = workspace.map { ProjectRef(rootURL: URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent)) }
            await sink.item(ScanItem(
                url: URL(fileURLWithPath: path), displayName: name, tool: Self.toolID, category: .systemJunk, project: project,
                sizeAllocated: size.allocatedBytes, sizeLogical: size.logicalBytes, fileCount: size.fileCount,
                lastModified: size.newestModification, tier: tier, explanation: variant.explanation,
                ruleID: Self.ruleID, cleanupMethod: .trash))
        }
    }

    /// D15: Keep when changed in the last day; Safe only when the project is gone and the folder is over 7 days old.
    func classify(workspace: String?, newest: Date?, now: Date) -> (RiskTier, DerivedDataVariant) {
        guard let newest else { return (.review, workspace == nil ? .unreadable : .projectExists) }
        let age = now.timeIntervalSince(newest)
        if age < 86_400 { return (.keep, .active) }
        guard let workspace else { return (.review, .unreadable) }
        guard projectIsGone(workspace) else { return (.review, .projectExists) }
        return age > 7 * 86_400 ? (.safe, .projectGone) : (.review, .projectGoneRecent)
    }

    /// Gone means "definitely missing": ENOENT, and, for a path on an external volume, only while that volume is mounted.
    func projectIsGone(_ workspace: String) -> Bool {
        var st = stat()
        guard lstat(workspace, &st) != 0, errno == ENOENT else { return false }
        let volumes = mountsRoot + "/"
        if workspace.hasPrefix(volumes) {
            let volume = workspace.dropFirst(volumes.count).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            var vs = stat()
            return !volume.isEmpty && stat(mountsRoot + "/" + volume, &vs) == 0
        }
        return true
    }

    /// `WorkspacePath` from `<folder>/info.plist`: a regular file (never a symlink) of at most 64 KiB, absolute path inside.
    static func workspacePath(inFolder folder: String) -> String? {
        let fd = open(folder + "/info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size <= maxPlistBytes else { return nil }
        var data = Data(count: Int(st.st_size))
        let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n == Int(st.st_size),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let path = plist["WorkspacePath"] as? String,
              path.hasPrefix("/"), path.utf8.count < 1024, !path.utf8.contains(0),
              !PathNormalization.containsParentReference(path) else { return nil }
        return PathNormalization.lexical(path)
    }

    static func childNames(of dir: String) -> [String] {
        guard let dp = opendir(dir) else { return [] }
        defer { closedir(dp) }
        var names: [String] = []
        while let entry = readdir(dp) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
