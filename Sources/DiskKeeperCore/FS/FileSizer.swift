import Darwin
import Foundation

public enum FileSizerError: Error, Sendable, Equatable {
    case notAFileURL(String)                          // url.isFileURL == false
    case rootNotFound(path: String)                   // lstat ENOENT/ENOTDIR on the root
    case rootInaccessible(path: String, errno: Int32) // lstat failed otherwise
    case walkFailed(path: String, errno: Int32)       // fts_open returned NULL
}

/// Sizes a directory tree without following symlinks (read-only; never reads file contents).
///
/// Semantics callers must know:
/// - **Allocated vs logical:** `allocatedBytes` is on-disk usage (`st_blocks * 512`, what `du` reports,
///   and what deleting would free); `logicalBytes` is the sum of file lengths (`st_size`).
/// - **Hardlinks** are deduplicated per call only (no cross-call dedupe). A hardlink whose other name
///   lives outside the tree is still counted once here; deleting it frees nothing.
/// - **APFS clones** are overcounted: shared extents are invisible to `stat`, so `allocatedBytes` is an
///   upper bound on reclaimable space when clones exist.
/// - **Mount points** on other devices are not crossed unless `Options.crossVolumes` is set.
/// - **Dataless** (iCloud / File Provider) directories are not materialized or descended.
/// - `progress` is called on a background (walker) thread.
public struct FileSizer: Sendable {
    public struct Options: Sendable, Hashable {
        /// Descend into directories on other devices. Default false (never cross volumes unless asked).
        public var crossVolumes: Bool
        /// Cap on `SizeReport.issues` (issueCount still counts all). Default 100.
        public var maxRecordedIssues: Int
        /// Call `progress` every N entries. Default 10_000. Must be >= 1.
        public var progressInterval: Int
        /// Dispatch QoS of the walker thread for the async API. Default .utility.
        public var qos: DispatchQoS.QoSClass
        /// TEST-ONLY hook invoked once per entry on the walker thread.
        var _entryHook: (@Sendable () -> Void)?

        public init(
            crossVolumes: Bool = false,
            maxRecordedIssues: Int = 100,
            progressInterval: Int = 10_000,
            qos: DispatchQoS.QoSClass = .utility
        ) {
            self.crossVolumes = crossVolumes
            self.maxRecordedIssues = maxRecordedIssues
            self.progressInterval = max(1, progressInterval)
            self.qos = qos
            self._entryHook = nil
        }

        public static func == (lhs: Options, rhs: Options) -> Bool {
            lhs.crossVolumes == rhs.crossVolumes && lhs.maxRecordedIssues == rhs.maxRecordedIssues
                && lhs.progressInterval == rhs.progressInterval && lhs.qos == rhs.qos
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(crossVolumes)
            hasher.combine(maxRecordedIssues)
            hasher.combine(progressInterval)
            hasher.combine(qos)
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Size the tree at `url` without following symlinks. Runs the walk on a GCD thread (not the
    /// cooperative pool). Throws `CancellationError` if the calling task is cancelled (checked before
    /// start and on every entry), or a `FileSizerError` for root-level failures. Errors BELOW the
    /// root never throw; they are recorded in `issues`.
    public func size(
        of url: URL,
        progress: (@Sendable (SizeProgress) -> Void)? = nil
    ) async throws -> SizeReport {
        try Task.checkCancellation()
        let flag = CancellationFlag()
        let qos = options.qos
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SizeReport, Error>) in
                DispatchQueue.global(qos: qos).async {
                    cont.resume(with: Result {
                        try self.sizeBlocking(of: url, shouldCancel: { flag.isSet }, progress: progress)
                    })
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    /// Synchronous core used by `size(of:)`, tests and benchmarks. Blocks the calling thread.
    /// Throws `CancellationError` as soon as `shouldCancel()` returns true (checked every entry).
    public func sizeBlocking(
        of url: URL,
        shouldCancel: @Sendable () -> Bool = { false },
        progress: (@Sendable (SizeProgress) -> Void)? = nil
    ) throws -> SizeReport {
        guard url.isFileURL else { throw FileSizerError.notAFileURL(url.absoluteString) }
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        var rootStat = stat()
        if lstat(path, &rootStat) != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw FileSizerError.rootNotFound(path: path) }
            throw FileSizerError.rootInaccessible(path: path, errno: code)
        }
        return try FileTreeWalker(options: options, path: path, rootStat: rootStat)
            .run(shouldCancel: shouldCancel, progress: progress)
    }
}
