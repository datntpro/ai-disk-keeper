import Darwin
import Foundation

/// Builds an in-memory ``DiskTree`` for a root in one read-only walk (never reads file content, never follows
/// symlinks, never crosses volumes, never descends dataless directories). See `docs/disk-index.md`.
public actor DiskIndexer {
    public enum Scope: Sendable, Hashable, Codable {
        case home
        case fullDisk
        case folder(String)
    }

    /// The data volume. `/` is the sealed system snapshot; user data is firmlinked in from here.
    static let dataVolumeRoot = "/System/Volumes/Data"

    private let environment: PathEnvironment
    private let pathGuard: ProtectedPaths
    private let options: IndexOptions
    private var runFlag: CancellationFlag?

    public private(set) var isRunning = false
    public private(set) var lastTree: DiskTree?

    public init(environment: PathEnvironment, pathGuard: ProtectedPaths, options: IndexOptions = .init()) {
        self.environment = environment
        self.pathGuard = pathGuard
        self.options = options
    }

    /// Scope → root path. `.folder` must be absolute, NUL-free and free of `..`.
    static func root(for scope: Scope, environment: PathEnvironment) throws -> String {
        switch scope {
        case .home: return environment.home
        case .fullDisk: return dataVolumeRoot
        case .folder(let p):
            guard PathNormalization.isAbsolute(p), !PathNormalization.containsNUL(p),
                  !PathNormalization.containsParentReference(p) else { throw DiskIndexerError.rootNotFound(p) }
            var path = p
            while path.utf8.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
    }

    /// One run at a time (`alreadyRunning`). Throws `CancellationError` when cancelled (task cancel or `cancel()`).
    public func index(_ scope: Scope, progress: (@Sendable (IndexProgress) -> Void)? = nil) async throws -> DiskTree {
        guard !isRunning else { throw DiskIndexerError.alreadyRunning }
        let root = try Self.root(for: scope, environment: environment)
        try Task.checkCancellation()
        var rootStat = stat()
        if lstat(root, &rootStat) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw DiskIndexerError.rootNotFound(root) }
            throw DiskIndexerError.rootInaccessible(root, code)
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else { throw DiskIndexerError.rootInaccessible(root, ENOTDIR) }

        let flag = CancellationFlag()
        runFlag = flag
        isRunning = true
        defer { isRunning = false; runFlag = nil }

        let walker = IndexWalker(options: options, rootPath: root, scope: scope, pathGuard: pathGuard, rootStat: rootStat)
        let qos = options.qos
        let tree = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DiskTree, Error>) in
                DispatchQueue.global(qos: qos).async {
                    cont.resume(with: Result { try walker.run(shouldCancel: { flag.isSet }, progress: progress) })
                }
            }
        } onCancel: {
            flag.set()
        }
        lastTree = tree
        return tree
    }

    /// Idempotent.
    public func cancel() { runFlag?.set() }
}
