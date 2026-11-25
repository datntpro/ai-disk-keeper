import Darwin
import Foundation

public enum FullDiskAccessStatus: Sendable, Equatable { case granted, notGranted, unknown }

/// Detects Full Disk Access by opening (never reading) locations macOS protects with TCC.
public struct FullDiskAccessProbe: Sendable {
    public let probePaths: [String]

    public init(probePaths: [String]) { self.probePaths = probePaths }

    public static func standard(environment: PathEnvironment) -> FullDiskAccessProbe {
        FullDiskAccessProbe(probePaths: [
            environment.applicationSupport + "/com.apple.TCC/TCC.db",
            environment.home + "/Library/Safari",
            environment.home + "/Library/Mail",
        ])
    }

    public func check() -> FullDiskAccessStatus {
        var sawAny = false
        for path in probePaths {
            var st = stat()
            // lstat on a TCC-protected path can itself fail with EPERM: that is "not granted".
            if lstat(path, &st) != 0 {
                if errno == EPERM || errno == EACCES { return .notGranted }
                continue
            }
            sawAny = true
            if (st.st_mode & S_IFMT) == S_IFDIR {
                guard let dir = opendir(path) else {
                    if errno == EPERM || errno == EACCES { return .notGranted }
                    continue
                }
                closedir(dir)
            } else {
                let fd = open(path, O_RDONLY)
                if fd < 0 {
                    if errno == EPERM || errno == EACCES { return .notGranted }
                    continue
                }
                close(fd)
            }
        }
        return sawAny ? .granted : .unknown
    }
}
