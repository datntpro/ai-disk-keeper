import Darwin
import Foundation

/// Metadata read from `Contents/Info.plist`.
struct BundleInfo: Equatable {
    var bundleID: String?
    var displayName: String?
    var bundleName: String?
    var version: String?
    var executable: String?
}

enum AppBundleReadError: Error, Equatable {
    case permissionDenied(Int32)
    case missingPlist
    case corruptPlist(String)
}

/// Read-only helpers for app bundles. Never uses `Bundle(url:)` (global cache, can load code).
enum AppBundleReader {
    static func read(bundlePath: String) throws -> BundleInfo {
        let plistPath = bundlePath + "/Contents/Info.plist"
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw AppBundleReadError.permissionDenied(EACCES)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw AppBundleReadError.missingPlist
        } catch {
            if let e = error as NSError?, e.domain == NSPOSIXErrorDomain, e.code == Int(EPERM) {
                throw AppBundleReadError.permissionDenied(EPERM)
            }
            throw AppBundleReadError.corruptPlist(error.localizedDescription)
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw AppBundleReadError.corruptPlist(error.localizedDescription)
        }
        guard let dict = object as? [String: Any] else { throw AppBundleReadError.corruptPlist("not a dictionary") }
        func string(_ key: String) -> String? {
            guard let s = dict[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        return BundleInfo(bundleID: string("CFBundleIdentifier"), displayName: string("CFBundleDisplayName"),
                          bundleName: string("CFBundleName"), version: string("CFBundleShortVersionString"),
                          executable: string("CFBundleExecutable"))
    }

    static func hasAppStoreReceipt(bundlePath: String) -> Bool {
        var st = stat()
        return lstat(bundlePath + "/Contents/_MASReceipt/receipt", &st) == 0
    }

    /// `lstat` of the entry itself: (isDirectory, isSymlink, owner). Nil if it can't be stat'ed.
    static func entryKind(_ path: String) -> (isDirectory: Bool, isSymlink: Bool, owner: UInt32)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK {
            var target = stat()
            let isDir = stat(path, &target) == 0 && (target.st_mode & S_IFMT) == S_IFDIR
            return (isDir, true, UInt32(st.st_uid))
        }
        return (type == S_IFDIR, false, UInt32(st.st_uid))
    }

    static func resolvedPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}

enum DirectoryLister {
    /// Entry names (no "." / ".."), sorted for determinism, or the errno that stopped the listing.
    static func names(at path: String) -> Result<[String], POSIXError> {
        guard let dp = opendir(path) else {
            return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        defer { closedir(dp) }
        var out: [String] = []
        while let entry = readdir(dp) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            out.append(name)
        }
        return .success(out.sorted())
    }
}
