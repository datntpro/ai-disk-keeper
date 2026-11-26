import Darwin
import Foundation

/// One Docker-compatible runtime AI Disk Keeper knows how to talk to.
public struct DockerRuntimeDefinition: Sendable, Hashable, Identifiable {
    /// `docker-desktop`, `orbstack`, `colima-<profile>`. Used as the virtual-path target.
    public let id: String
    public let displayName: String
    /// Absolute, first safe one wins. Never `PATH`.
    public let cliCandidates: [String]
    public let socketPath: String
    public let appBundles: [String]
    /// Concrete files (globs already expanded). Only ever `lstat`ed.
    public let diskImagePaths: [String]

    public init(id: String, displayName: String, cliCandidates: [String], socketPath: String,
                appBundles: [String] = [], diskImagePaths: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.cliCandidates = cliCandidates
        self.socketPath = socketPath
        self.appBundles = appBundles
        self.diskImagePaths = diskImagePaths
    }
}

/// Every path the Docker support looks at. `live(environment:)` is used only by the app wiring; tests build
/// layouts that point into temp directories.
public struct DockerRuntimeLayout: Sendable {
    /// Sockets must live under this directory (after `realpath`).
    public let home: String
    private let definitions: @Sendable () -> [DockerRuntimeDefinition]

    public init(home: String, definitions: @escaping @Sendable () -> [DockerRuntimeDefinition]) {
        self.home = home
        self.definitions = definitions
    }

    public func runtimes() -> [DockerRuntimeDefinition] { definitions() }
    public func runtime(id: String) -> DockerRuntimeDefinition? { definitions().first { $0.id == id } }

    public static func live(environment: PathEnvironment) -> DockerRuntimeLayout {
        let home = environment.home
        return DockerRuntimeLayout(home: home) {
            var out: [DockerRuntimeDefinition] = [
                DockerRuntimeDefinition(
                    id: "docker-desktop", displayName: "Docker Desktop",
                    cliCandidates: [home + "/.docker/bin/docker", "/usr/local/bin/docker",
                                    "/Applications/Docker.app/Contents/Resources/bin/docker"],
                    socketPath: home + "/.docker/run/docker.sock",
                    appBundles: ["/Applications/Docker.app"],
                    diskImagePaths: subdirectories(home + "/Library/Containers/com.docker.docker/Data/vms")
                        .map { $0 + "/data/Docker.raw" }),
                DockerRuntimeDefinition(
                    id: "orbstack", displayName: "OrbStack",
                    cliCandidates: [home + "/.orbstack/bin/docker", "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
                                    "/usr/local/bin/docker"],
                    socketPath: home + "/.orbstack/run/docker.sock",
                    appBundles: ["/Applications/OrbStack.app"],
                    diskImagePaths: [home + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img"]),
            ]
            let reserved: Set<String> = ["_lima", "_templates", "_config"]
            for profile in subdirectories(home + "/.colima").map({ ($0 as NSString).lastPathComponent })
            where !reserved.contains(profile) && !profile.hasPrefix(".") && isSafeProfile(profile) {
                let lima = profile == "default" ? "colima" : "colima-\(profile)"
                out.append(DockerRuntimeDefinition(
                    id: "colima-\(profile)", displayName: profile == "default" ? "Colima" : "Colima (\(profile))",
                    cliCandidates: ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"],
                    socketPath: home + "/.colima/\(profile)/docker.sock",
                    diskImagePaths: [home + "/.colima/_lima/_disks/\(profile)/datadisk",
                                     home + "/.colima/_lima/\(lima)/diffdisk"]))
            }
            return out
        }
    }

    /// Profile names become path components and ids: keep them plain.
    static func isSafeProfile(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    private static func subdirectories(_ dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted().map { dir + "/" + $0 }.filter { path in
            var st = stat()
            return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }
    }

    // MARK: Socket

    /// `lstat` must show a socket owned by `uid`. A symlink is followed once with `realpath`, and the result must
    /// again be a user-owned socket under `home`. Returns the real path.
    public func validatedSocket(_ path: String, userID: uid_t = getuid()) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var real = path
        if (st.st_mode & S_IFMT) == S_IFLNK {
            guard let r = realpath(path, nil) else { return nil }
            defer { free(r) }
            real = String(cString: r)
            guard real.hasPrefix(Self.realHome(home) + "/") || real.hasPrefix(home + "/") else { return nil }
            guard lstat(real, &st) == 0 else { return nil }
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == userID else { return nil }
        guard !real.utf8.contains(0), real.hasPrefix("/") else { return nil }
        guard let r = realpath(real, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    private static func realHome(_ home: String) -> String {
        guard let r = realpath(home, nil) else { return home }
        defer { free(r) }
        return String(cString: r)
    }
}

/// The VM disk image. Taken with `lstat` only: never opened, read, edited, trashed or deleted.
public struct DockerDiskImage: Sendable, Hashable {
    public let path: String
    public let allocatedBytes: Int64
    public let logicalBytes: Int64

    public static func stat(_ paths: [String]) -> DockerDiskImage? {
        for p in paths {
            var st = Darwin.stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            return DockerDiskImage(path: p, allocatedBytes: Int64(st.st_blocks) * 512, logicalBytes: Int64(st.st_size))
        }
        return nil
    }
}
