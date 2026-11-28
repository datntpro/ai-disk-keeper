import Darwin
import Foundation

public enum TartTmpVariant: String, Sendable, CaseIterable {
    case active, old

    public var explanation: String {
        switch self {
        case .active:
            "Regenerable: a partial download or scratch file Tart is writing or wrote in the last day. A pull or clone may be using it. Kept."
        case .old:
            "Regenerable: a partial download or scratch file Tart left behind when a pull or clone was interrupted. Tart starts it again."
        }
    }

    public static func of(_ item: ScanItem) -> TartTmpVariant? {
        guard item.ruleID == TartTmpScanner.ruleID else { return nil }
        return allCases.first { $0.explanation == item.explanation }
    }
}

/// The children of `~/.tart/tmp`: Safe when over a day old, Keep otherwise. It is a scanner, not a rule, because a Safe
/// item needs a folder that resolves to itself (`BuildCacheRoot`): a symlinked `~/.tart` must not make Safe items elsewhere.
public struct TartTmpScanner: Scanner {
    public static let ruleID = "build-caches.tart-tmp"
    public let id = "build-caches.tart-tmp"
    private let root: String
    private let home: String

    public init(root: String, home: String) {
        self.root = root
        self.home = home
    }

    public static func live(environment: PathEnvironment) -> TartTmpScanner {
        TartTmpScanner(root: environment.home + "/.tart/tmp", home: environment.home)
    }

    public func scan(context: ScanContext, sink: ScanSink) async throws {
        var st = stat()
        guard lstat(root, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == context.userID,
              BuildCacheRoot.resolvesToItself(root, home: home) else { return }
        for name in DerivedDataScanner.childNames(of: root).sorted() {
            try Task.checkCancellation()
            guard !name.hasPrefix(".") else { continue }
            let path = root + "/" + name
            var cs = stat()
            guard lstat(path, &cs) == 0, (cs.st_mode & S_IFMT) != S_IFLNK, cs.st_uid == context.userID,
                  context.pathGuard.check(path).isAllowed,
                  let size = try? await context.size(URL(fileURLWithPath: path)) else { continue }
            let fresh = size.newestModification.map { context.now.timeIntervalSince($0) < 86_400 } ?? true
            let variant: TartTmpVariant = fresh ? .active : .old
            await sink.item(ScanItem(
                url: URL(fileURLWithPath: path), displayName: name, tool: DerivedDataScanner.toolID, category: .systemJunk,
                sizeAllocated: size.allocatedBytes, sizeLogical: size.logicalBytes, fileCount: size.fileCount,
                lastModified: size.newestModification, tier: fresh ? .keep : .safe, explanation: variant.explanation,
                ruleID: Self.ruleID, cleanupMethod: .trash))
        }
    }
}
