import Foundation

/// Pure lexical path helpers. No filesystem access.
///
/// Deliberately avoids `standardizingPath` / `standardizedFileURL`, which strip `/private`.
/// All splitting and prefix checks work on Unicode scalars / UTF-8 bytes, never on `Character`s:
/// a combining mark after "/" would otherwise fuse with it into one Character while the kernel
/// still sees a separator.
public enum PathNormalization {
    /// True if the path starts with the byte "/".
    public static func isAbsolute(_ path: String) -> Bool { path.utf8.first == 0x2F }

    /// True if the path contains a NUL scalar.
    public static func containsNUL(_ path: String) -> Bool { path.utf8.contains(0) }

    private static func split(_ path: String) -> [String] {
        path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: true)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// Lexical cleanup only: collapses "//", removes "." components and trailing "/", resolves ".."
    /// lexically (".." at root stays at root). Never strips "/private", never resolves symlinks, never
    /// changes case or Unicode form. A relative input is returned unchanged. "" -> "".
    public static func lexical(_ path: String) -> String {
        guard isAbsolute(path) else { return path }
        var stack: [String] = []
        for c in split(path) {
            if c == "." { continue }
            if c == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(c)
        }
        return "/" + stack.joined(separator: "/")
    }

    /// True if any "/"-separated component is exactly "..".
    public static func containsParentReference(_ path: String) -> Bool {
        split(path).contains("..")
    }

    /// Components of an absolute path without the leading "/" ("/" -> []).
    public static func components(_ path: String) -> [Substring] {
        split(path).map { Substring($0) }
    }
}
