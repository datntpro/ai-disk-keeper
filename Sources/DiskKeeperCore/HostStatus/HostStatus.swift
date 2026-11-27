import Foundation

public enum HostStatusLevel: String, Codable, Sendable, Comparable {
    case ok, warn, critical
    private var rank: Int { switch self { case .ok: 0; case .warn: 1; case .critical: 2 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum HostStatusReasonCode: String, Codable, Sendable {
    case lowFreeSpace, fullSoon, highDiskWrites, highLoad, memoryPressure
}

/// `status.json` schema v1 (docs/host-status.md). Unknown values are `null`, never omitted. No argv, no file contents.
public struct HostStatus: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let maxTopWriters = 10
    public static let maxWorktrees = 20

    public struct Generator: Codable, Sendable, Equatable {
        public var app: String, version: String
        public var pid: Int32
        public init(app: String = "AI Disk Keeper", version: String, pid: Int32) { self.app = app; self.version = version; self.pid = pid }
    }

    public struct Reason: Codable, Sendable, Equatable {
        public var code: HostStatusReasonCode, message: String
        public init(code: HostStatusReasonCode, message: String) { self.code = code; self.message = message }
    }

    public struct Disk: Codable, Sendable, Equatable {
        public var volume: String
        public var totalBytes: Int64, freeBytes: Int64
        public var freePercent: Double
        public var thresholdPercent: Int
        public var trendBytesPerHour: Double?
        public var timeToFullHours: Double?
        public init(volume: String, totalBytes: Int64, freeBytes: Int64, freePercent: Double, thresholdPercent: Int,
                    trendBytesPerHour: Double?, timeToFullHours: Double?) {
            self.volume = volume; self.totalBytes = totalBytes; self.freeBytes = freeBytes; self.freePercent = freePercent
            self.thresholdPercent = thresholdPercent; self.trendBytesPerHour = trendBytesPerHour; self.timeToFullHours = timeToFullHours
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(volume, forKey: .volume); try c.encode(totalBytes, forKey: .totalBytes); try c.encode(freeBytes, forKey: .freeBytes)
            try c.encode(freePercent, forKey: .freePercent); try c.encode(thresholdPercent, forKey: .thresholdPercent)
            try c.encode(trendBytesPerHour, forKey: .trendBytesPerHour); try c.encode(timeToFullHours, forKey: .timeToFullHours)
        }
    }

    public struct IO: Codable, Sendable, Equatable {
        public var readBytesPerSec: Double, writeBytesPerSec: Double
        public var busyPercent: Double?
        public var sampleSeconds: Double
        public init(readBytesPerSec: Double, writeBytesPerSec: Double, busyPercent: Double?, sampleSeconds: Double) {
            self.readBytesPerSec = readBytesPerSec; self.writeBytesPerSec = writeBytesPerSec
            self.busyPercent = busyPercent; self.sampleSeconds = sampleSeconds
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(readBytesPerSec, forKey: .readBytesPerSec); try c.encode(writeBytesPerSec, forKey: .writeBytesPerSec)
            try c.encode(busyPercent, forKey: .busyPercent); try c.encode(sampleSeconds, forKey: .sampleSeconds)
        }
    }

    public struct Load: Codable, Sendable, Equatable {
        public var loadAverage1: Double
        public var cpuCount: Int
        /// "normal" | "warning" | "critical" | null.
        public var memoryPressure: String?
        public init(loadAverage1: Double, cpuCount: Int, memoryPressure: String?) {
            self.loadAverage1 = loadAverage1; self.cpuCount = cpuCount; self.memoryPressure = memoryPressure
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(loadAverage1, forKey: .loadAverage1); try c.encode(cpuCount, forKey: .cpuCount)
            try c.encode(memoryPressure, forKey: .memoryPressure)
        }
    }

    public struct Writer: Codable, Sendable, Equatable {
        public var pid: Int32
        public var name: String
        public var agent: String?
        public var worktree: String?
        public var writeBytesPerSec: Double
        public init(pid: Int32, name: String, agent: String?, worktree: String?, writeBytesPerSec: Double) {
            self.pid = pid; self.name = name; self.agent = agent; self.worktree = worktree; self.writeBytesPerSec = writeBytesPerSec
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pid, forKey: .pid); try c.encode(name, forKey: .name); try c.encode(agent, forKey: .agent)
            try c.encode(worktree, forKey: .worktree); try c.encode(writeBytesPerSec, forKey: .writeBytesPerSec)
        }
    }

    public struct Worktree: Codable, Sendable, Equatable {
        public var path: String, repo: String
        public var writeBytesPerSec: Double
        public var processCount: Int
        public var agents: [String]
        public init(path: String, repo: String, writeBytesPerSec: Double, processCount: Int, agents: [String]) {
            self.path = path; self.repo = repo; self.writeBytesPerSec = writeBytesPerSec; self.processCount = processCount; self.agents = agents
        }
    }

    /// Filled by the worktree inventory (H3); `null` until then.
    public struct Inventory: Codable, Sendable, Equatable {
        public var count: Int, safeToClean: Int
        public var safeBytes: Int64
        public init(count: Int, safeToClean: Int, safeBytes: Int64) { self.count = count; self.safeToClean = safeToClean; self.safeBytes = safeBytes }
    }

    public var schemaVersion: Int = HostStatus.schemaVersion
    public var generatedAt: Date
    public var intervalSeconds: Int
    public var running: Bool
    public var generator: Generator
    public var level: HostStatusLevel
    public var reasons: [Reason]
    public var disk: Disk?
    public var io: IO?
    public var load: Load
    public var topWriters: [Writer]
    public var worktrees: [Worktree]
    public var inventory: Inventory?

    public init(generatedAt: Date, intervalSeconds: Int, running: Bool, generator: Generator, level: HostStatusLevel, reasons: [Reason],
                disk: Disk?, io: IO?, load: Load, topWriters: [Writer], worktrees: [Worktree], inventory: Inventory? = nil) {
        self.generatedAt = generatedAt; self.intervalSeconds = intervalSeconds; self.running = running; self.generator = generator
        self.level = level; self.reasons = reasons; self.disk = disk; self.io = io; self.load = load
        self.topWriters = Array(topWriters.prefix(Self.maxTopWriters)); self.worktrees = Array(worktrees.prefix(Self.maxWorktrees))
        self.inventory = inventory
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(intervalSeconds, forKey: .intervalSeconds); try c.encode(running, forKey: .running)
        try c.encode(generator, forKey: .generator); try c.encode(level, forKey: .level); try c.encode(reasons, forKey: .reasons)
        try c.encode(disk, forKey: .disk); try c.encode(io, forKey: .io); try c.encode(load, forKey: .load)
        try c.encode(topWriters, forKey: .topWriters); try c.encode(worktrees, forKey: .worktrees); try c.encode(inventory, forKey: .inventory)
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
