import Foundation

/// Aggregate progress of one scan, as reported to the UI. Counts are summed over every scanner's latest
/// `ScannerProgress`; `itemsFound` counts accepted items only. `bytesFound` is accepted items plus whatever
/// scanners report while still sizing candidates (never decreasing); the last progress before a terminal event
/// is exact (accepted items only).
public struct ScanProgress: Sendable, Hashable {
    public var scannersFinished: Int
    public var scannersTotal: Int
    public var candidatesFound: Int
    public var candidatesSized: Int
    public var itemsFound: Int
    public var bytesFound: Int64

    public init(scannersFinished: Int = 0, scannersTotal: Int = 0, candidatesFound: Int = 0,
                candidatesSized: Int = 0, itemsFound: Int = 0, bytesFound: Int64 = 0) {
        self.scannersFinished = scannersFinished
        self.scannersTotal = scannersTotal
        self.candidatesFound = candidatesFound
        self.candidatesSized = candidatesSized
        self.itemsFound = itemsFound
        self.bytesFound = bytesFound
    }
}

/// Events of one scan. Contract: `started` first (once); exactly one terminal event (`finished` or
/// `cancelled`) last, after which the stream ends and nothing more is delivered. Every `itemFound` item passed
/// the guard and overlaps no other item; `ScanResult.items` equals the `itemFound` items, in order.
public enum ScanEvent: Sendable {
    case started(id: UUID, startedAt: Date, scannerIDs: [String])
    case itemFound(ScanItem)
    case progress(ScanProgress)
    case warning(ScanWarning)
    /// `wasCancelled == false`.
    case finished(ScanResult)
    /// Partial result; `wasCancelled == true`, `finishedAt` set.
    case cancelled(ScanResult)
}
