import Foundation

public struct LocalSnapshot: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case timeMachine, osUpdate, other }

    public let name: String
    /// Parsed from `YYYY-MM-DD-HHMMSS` in a Time Machine name; nil for other formats.
    public let date: Date?
    public let kind: Kind

    public init(name: String, date: Date?, kind: Kind) {
        self.name = name
        self.date = date
        self.kind = kind
    }
}

public enum SnapshotUnavailableReason: Sendable, Hashable, Codable {
    case toolMissing
    case timedOut
    case failed(exitStatus: Int32)
    case badVolume
}

public enum SnapshotListing: Sendable, Hashable {
    case listed([LocalSnapshot])
    case unavailable(SnapshotUnavailableReason)
}

/// Lists APFS local snapshots with `tmutil listlocalsnapshots`. This is the ONLY tmutil subcommand the app uses; it is read-only.
/// Sizes are not reported: tmutil does not give them.
public struct LocalSnapshotLister: Sendable {
    /// The only subcommand. `list` appends the volume path and nothing else.
    static let arguments = ["listlocalsnapshots"]

    private let runner: ProcessRunner
    private let timeout: Duration
    private let executable: URL

    public init(
        runner: ProcessRunner = ProcessRunner(maxOutputBytes: 1 << 20), timeout: Duration = .seconds(10),
        executable: URL = URL(fileURLWithPath: "/usr/bin/tmutil")
    ) {
        self.runner = runner
        self.timeout = timeout
        self.executable = executable
    }

    /// Never throws except `CancellationError`.
    public func list(volume: String = "/") async throws -> SnapshotListing {
        guard volume.hasPrefix("/"), !volume.split(separator: "/").contains("..") else {
            return .unavailable(.badVolume)
        }
        do {
            let r = try await runner.run(
                executable: executable, arguments: Self.arguments + [volume],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
            guard r.exitStatus == 0 else { return .unavailable(.failed(exitStatus: r.exitStatus)) }
            return .listed(Self.parse(r.stdoutString))
        } catch is CancellationError {
            throw CancellationError()
        } catch ProcessRunnerError.timedOut {
            return .unavailable(.timedOut)
        } catch {
            return .unavailable(.toolMissing)
        }
    }

    /// Skips blank lines and the "Snapshots for ..." header. Time Machine names carry local wall-clock time.
    static func parse(_ stdout: String, timeZone: TimeZone = .current) -> [LocalSnapshot] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let re = try! NSRegularExpression(pattern: #"^com\.apple\.TimeMachine\.(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})"#)
        var out: [LocalSnapshot] = []
        for raw in stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("Snapshots for") { continue }
            if line.hasPrefix("com.apple.os.update-") {
                out.append(LocalSnapshot(name: line, date: nil, kind: .osUpdate))
            } else if let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let n = (1...6).map { Int(line[Range(m.range(at: $0), in: line)!])! }
                let date = cal.date(from: DateComponents(
                    year: n[0], month: n[1], day: n[2], hour: n[3], minute: n[4], second: n[5]))
                out.append(LocalSnapshot(name: line, date: date, kind: .timeMachine))
            } else {
                out.append(LocalSnapshot(name: line, date: nil, kind: .other))
            }
        }
        return out
    }
}
