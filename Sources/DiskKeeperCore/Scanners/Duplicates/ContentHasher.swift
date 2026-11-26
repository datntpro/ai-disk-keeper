import CryptoKit
import Darwin
import Foundation

/// What the file must still look like when we open it. A mismatch means "changed since the index".
struct FileIdentity: Sendable, Hashable {
    let device: Int32
    let inode: UInt64
    let size: Int64
}

enum HashOutcome: Sendable, Equatable {
    case digest(String, bytesRead: Int64)
    /// Replaced, resized, no longer a regular file, or now a symlink.
    case changed
    /// `SF_DATALESS`: never read.
    case dataless
    case unreadable(Int32)
}

/// Blocking open/pread/SHA-256 on a GCD thread. Never `mmap` (a truncated file would SIGBUS), never follows
/// symlinks, never materializes a dataless file, never fills the page cache.
enum ContentHasher {
    static let chunkSize = 1 << 20
    static let edgeBytes = 65_536

    // MARK: Async entry points

    /// `SHA-256(UInt64 size BE ‖ first 64 KiB ‖ last 64 KiB)` as hex.
    static func partialDigest(path: String, identity: FileIdentity) async throws -> HashOutcome {
        try await run { flag in hash(path: path, identity: identity, full: false, flag: flag) }
    }

    /// Streamed SHA-256 over the whole file as hex.
    static func fullDigest(path: String, identity: FileIdentity) async throws -> HashOutcome {
        try await run { flag in hash(path: path, identity: identity, full: true, flag: flag) }
    }

    private static func run(_ job: @escaping @Sendable (CancellationFlag) -> HashOutcome?) async throws -> HashOutcome {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HashOutcome, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    if let outcome = job(flag) { cont.resume(returning: outcome) } else { cont.resume(throwing: CancellationError()) }
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    // MARK: Blocking core

    /// nil when cancelled.
    static func hash(path: String, identity: FileIdentity, full: Bool, flag: CancellationFlag) -> HashOutcome? {
        if flag.isSet { return nil }
        // Pooled threads keep their policy: switch "materialize dataless files" off for this job only.
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous) }

        var fd: Int32
        repeat { fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) } while fd < 0 && errno == EINTR
        if fd < 0 {
            let code = errno
            if code == ELOOP { return .changed }
            if code == ENOENT || code == ENOTDIR { return .changed }
            return .unreadable(code)
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable(errno) }
        if st.st_flags & UInt32(SF_DATALESS) != 0 { return .dataless }
        guard (st.st_mode & S_IFMT) == S_IFREG,
              Int32(truncatingIfNeeded: st.st_dev) == identity.device, UInt64(st.st_ino) == identity.inode,
              Int64(st.st_size) == identity.size else { return .changed }
        _ = fcntl(fd, F_NOCACHE, 1)
        _ = fcntl(fd, F_RDAHEAD, 1)

        var hasher = SHA256()
        var bytesRead: Int64 = 0
        let size = identity.size
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        defer { buffer.deallocate() }

        /// Reads `[offset, offset+count)` into the hasher. Returns an outcome on failure.
        func feed(offset: Int64, count: Int64) -> HashOutcome?? {
            var done: Int64 = 0
            while done < count {
                if flag.isSet { return .some(nil) }
                let want = Int(min(Int64(chunkSize), count - done))
                var n: Int
                repeat { n = pread(fd, buffer, want, off_t(offset + done)) } while n < 0 && errno == EINTR
                if n < 0 { return .some(.unreadable(errno)) }
                if n == 0 { return .some(.changed) }   // shorter than recorded: truncated meanwhile
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
                done += Int64(n)
                bytesRead += Int64(n)
            }
            return nil
        }

        if full {
            if let failure = feed(offset: 0, count: size) { return failure }
        } else {
            var be = UInt64(size).bigEndian
            withUnsafeBytes(of: &be) { hasher.update(bufferPointer: $0) }
            let head = min(Int64(edgeBytes), size)
            if let failure = feed(offset: 0, count: head) { return failure }
            let tail = min(Int64(edgeBytes), size)
            if let failure = feed(offset: size - tail, count: tail) { return failure }
        }
        if flag.isSet { return nil }
        // The file must still be the one we sized: a grown or shrunk file would make the digest meaningless.
        var after = stat()
        if fstat(fd, &after) != 0 || Int64(after.st_size) != size { return .changed }
        return .digest(hex(hasher.finalize()), bytesRead: bytesRead)
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
