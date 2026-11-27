import Foundation

/// The volume users fill: the APFS Data volume. `/` is the sealed system volume and reports the shared container,
/// so free space is measured on the Data volume everywhere. `/` only when the Data volume is missing (a non-APFS test machine).
public enum DataVolume {
    public static let dataPath = "/System/Volumes/Data"

    public static let path: String = {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dataPath, isDirectory: &isDir) && isDir.boolValue ? dataPath : "/"
    }()
}
