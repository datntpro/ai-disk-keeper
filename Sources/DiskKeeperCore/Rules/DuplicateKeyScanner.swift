import Foundation

/// `JSONDecoder` silently keeps one value when an object repeats a key, while jq, editors and JSON Schema
/// tools may show another. This scanner finds the first repeated key so the loader can reject the file.
/// It is a tolerant pre-pass: on anything it doesn't understand (or nesting beyond `maxDepth`) it gives up
/// and returns nil, leaving syntax errors to `JSONDecoder`.
enum DuplicateKeyScanner {
    struct Duplicate: Equatable { let path: String; let key: String }

    static let maxDepth = 64

    static func firstDuplicate(in data: Data) -> Duplicate? {
        var scanner = Scanner(bytes: [UInt8](data))
        return try? scanner.scanDocument()
    }

    private struct Abort: Error {}
    private struct Found: Error { let dup: Duplicate }

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        // Returns nil if no duplicate; throws Found on the first duplicate; Abort when it gives up.
        mutating func scanDocument() throws -> Duplicate? {
            do {
                if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
                try value(path: "", depth: 0)
                return nil
            } catch let f as Found {
                return f.dup
            } catch {
                return nil
            }
        }

        mutating func ws() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value(path: String, depth: Int) throws {
            guard depth <= DuplicateKeyScanner.maxDepth else { throw Abort() }
            ws()
            guard i < bytes.count else { throw Abort() }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var seen = Set<String>()
                ws()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return }
                while true {
                    ws()
                    let key = try string()
                    if !seen.insert(key).inserted { throw Found(dup: Duplicate(path: path, key: key)) }
                    ws()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw Abort() }
                    i += 1
                    try value(path: path.isEmpty ? key : "\(path).\(key)", depth: depth + 1)
                    ws()
                    guard i < bytes.count else { throw Abort() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return }
                    throw Abort()
                }
            case UInt8(ascii: "["):
                i += 1
                ws()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return }
                var index = 0
                while true {
                    try value(path: "\(path)[\(index)]", depth: depth + 1)
                    index += 1
                    ws()
                    guard i < bytes.count else { throw Abort() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return }
                    throw Abort()
                }
            case UInt8(ascii: "\""):
                _ = try string()
            default:
                // number / true / false / null: skip to a delimiter
                while i < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
            }
        }

        /// Parses a string at `i` and returns its decoded content (escapes resolved).
        mutating func string() throws -> String {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw Abort() }
            i += 1
            var raw: [UInt8] = []
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    // Let Foundation resolve escapes so "a" and "a" compare equal.
                    let quoted = Data([UInt8(ascii: "\"")] + raw + [UInt8(ascii: "\"")])
                    guard let s = try? JSONDecoder().decode(String.self, from: quoted) else { throw Abort() }
                    return s
                }
                if b == UInt8(ascii: "\\") {
                    guard i + 1 < bytes.count else { throw Abort() }
                    raw.append(b); raw.append(bytes[i + 1]); i += 2
                    continue
                }
                raw.append(b)
                i += 1
            }
            throw Abort()
        }
    }
}
