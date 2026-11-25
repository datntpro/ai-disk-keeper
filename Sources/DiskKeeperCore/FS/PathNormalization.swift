import Foundation

/// Pure lexical path helpers. No filesystem access.
///
/// Deliberately avoids `standardizingPath` / `standardizedFileURL`, which strip `/private`.
public enum PathNormalization {
    /// Lexical cleanup only: collapses "//", removes "." components and trailing "/", resolves ".."
    /// lexically (".." at root stays at root). Never strips "/private", never resolves symlinks, never
    /// changes case or Unicode form. A relative input is returned unchanged. "" -> "".
    public static func lexical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var stack: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
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
        path.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    /// Components of an absolute path without the leading "/" ("/" -> []).
    public static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }
}
