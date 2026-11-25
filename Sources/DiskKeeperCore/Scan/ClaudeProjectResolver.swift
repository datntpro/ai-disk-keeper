import Darwin
import Foundation

/// Resolves `project.from: "claudeProjectDirName"`.
///
/// Claude encodes a working directory by replacing every non-alphanumeric character with `-`, which is lossy.
/// So the directory name is NOT reversed by listing the filesystem (that could raise TCC prompts in
/// `~/Documents` or `~/Desktop`). Instead the newest transcript's first `cwd` field is read.
/// Per-scan cache; not thread-safe, owned by one `RuleScanner` run. Read-only.
struct ClaudeProjectResolver {
    static let readLimit = 64 * 1024

    private var cache: [String: ProjectRef] = [:]

    mutating func project(forProjectDir dir: String, encodedName: String) -> ProjectRef {
        if let cached = cache[dir] { return cached }
        let ref = Self.cwd(inProjectDir: dir).map { ProjectRef(rootURL: URL(fileURLWithPath: $0)) }
            ?? Self.fallback(encodedName: encodedName)
        cache[dir] = ref
        return ref
    }

    static func fallback(encodedName: String) -> ProjectRef {
        let token = encodedName.split(separator: "-", omittingEmptySubsequences: true).last.map(String.init)
        return ProjectRef(id: "name:" + encodedName, displayName: token ?? encodedName)
    }

    private static func newestTranscript(in dir: String) -> String? {
        guard let dp = opendir(dir) else { return nil }
        defer { closedir(dp) }
        var best: (path: String, mtime: timespec)?
        while let entry = readdir(dp) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let name, name.hasSuffix(".jsonl") else { continue }
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let t = st.st_mtimespec
            if let b = best, (b.mtime.tv_sec, b.mtime.tv_nsec) >= (t.tv_sec, t.tv_nsec) { continue }
            best = (path, t)
        }
        return best?.path
    }

    private static func cwd(inProjectDir dir: String) -> String? {
        guard let file = newestTranscript(in: dir) else { return nil }
        // Open without following links or blocking (a swap after the lstat to a symlink/FIFO), then re-check
        // the opened descriptor is a regular file.
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: readLimit), !data.isEmpty else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // A truncated read ends mid-line: the last segment is incomplete unless the data ends with "\n".
        if data.count >= readLimit, data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = obj["cwd"] as? String,
                  PathNormalization.isAbsolute(cwd), !PathNormalization.containsNUL(cwd),
                  !PathNormalization.containsParentReference(cwd) else { continue }
            let clean = PathNormalization.lexical(cwd)
            if clean != "/" { return clean }
        }
        return nil
    }
}
