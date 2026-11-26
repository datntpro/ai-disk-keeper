import Foundation

public struct IndexOptions: Sendable, Hashable {
    /// Files at least this large get their own node; smaller ones fold into one "small items" node per directory.
    public var fileNodeThreshold: Int64 = 1 << 20
    /// Regular files at least this large (outside packages) get a ``FileRecord``.
    public var fileRecordThreshold: Int64 = 1 << 20
    /// Node budget. Beyond it, deeper directories fold into their nearest materialized ancestor.
    public var maxNodes: Int = 5_000_000
    public var maxFileRecords: Int = 2_000_000
    public var maxRecordedIssues: Int = 200
    public var progressInterval: Duration = .milliseconds(100)
    public var qos: DispatchQoS.QoSClass = .utility
    /// TEST-ONLY hook invoked once per entry on the walker thread.
    var _entryHook: (@Sendable () -> Void)?
    /// TEST-ONLY: pretend a path has SF_DATALESS.
    var _datalessOverride: (@Sendable (String) -> Bool)?
    /// TEST-ONLY override of the firmlinks file.
    var _firmlinksFile: String = "/usr/share/firmlinks"

    public init() {}

    public static func == (l: IndexOptions, r: IndexOptions) -> Bool {
        l.fileNodeThreshold == r.fileNodeThreshold && l.fileRecordThreshold == r.fileRecordThreshold
            && l.maxNodes == r.maxNodes && l.maxFileRecords == r.maxFileRecords
            && l.maxRecordedIssues == r.maxRecordedIssues && l.progressInterval == r.progressInterval
            && l.qos == r.qos && l._firmlinksFile == r._firmlinksFile
    }

    public func hash(into h: inout Hasher) {
        h.combine(fileNodeThreshold); h.combine(fileRecordThreshold); h.combine(maxNodes)
        h.combine(maxFileRecords); h.combine(maxRecordedIssues); h.combine(progressInterval)
        h.combine(qos); h.combine(_firmlinksFile)
    }
}

public struct IndexProgress: Sendable, Hashable {
    public var entriesVisited: Int
    public var directoriesVisited: Int
    public var allocatedBytesSoFar: Int64
    public var currentDirectory: String?

    public init(entriesVisited: Int, directoriesVisited: Int, allocatedBytesSoFar: Int64, currentDirectory: String? = nil) {
        self.entriesVisited = entriesVisited
        self.directoriesVisited = directoriesVisited
        self.allocatedBytesSoFar = allocatedBytesSoFar
        self.currentDirectory = currentDirectory
    }
}

public struct IndexStats: Sendable, Hashable {
    public var entriesVisited = 0
    public var directoryCount = 0
    public var fileCount = 0
    public var symlinkCount = 0
    public var hardlinkRepeatCount = 0
    public var datalessCount = 0
    public var skippedMountPoints: [String] = []
    public var issues: [SizingIssue] = []
    public var issueCount = 0
    public var nodeBudgetHit = false
    public var fileRecordsTruncated = false
    public var duration: Duration = .zero

    public init() {}

    /// True when nothing was lost: no read errors, no budget folding, no truncated records.
    public var isComplete: Bool { issueCount == 0 && !nodeBudgetHit && !fileRecordsTruncated }
}

public enum DiskIndexerError: Error, Sendable, Equatable {
    case alreadyRunning
    case rootNotFound(String)
    case rootInaccessible(String, Int32)
    case walkFailed(String, Int32)
}
