import Foundation

/// H6: "Shown X · frees about Y" for a selection. Shown is what we sum everywhere (allocated bytes); frees-about is
/// the honest, lower number. Information only: it never blocks, deselects or re-tiers anything, and it never adds
/// the volume's purgeable space. When unsure it reports LESS, not more.
public struct ReclaimEstimate: Sendable, Hashable {
    public enum Caveat: Sendable, Hashable {
        /// The Trash is on the same volume: the space returns only when the Trash is emptied.
        case trashSameVolume
        /// Local snapshots exist: macOS may keep the blocks used until it thins them.
        case localSnapshotsPresent
        /// Blocks shared with copies elsewhere (clones, hard links outside the item) stay used.
        case clonesShared(bytes: Int64)
        /// This many items could not be probed (non-APFS volume, error): they may free less than shown.
        case unknownForSome(count: Int)
    }

    /// Σ `sizeAllocated`.
    public let shownBytes: Int64
    /// Σ `reclaimableBytes` (items not probed count at their shown size). ≤ `shownBytes`.
    public let freesAboutBytes: Int64
    public let caveats: [Caveat]

    public init(shownBytes: Int64, freesAboutBytes: Int64, caveats: [Caveat]) {
        self.shownBytes = max(0, shownBytes)
        self.freesAboutBytes = max(0, min(freesAboutBytes, shownBytes))
        self.caveats = caveats
    }

    /// True when frees-about is under half of what is shown: the review sheet highlights it.
    public var isMuchSmaller: Bool { Double(freesAboutBytes) < 0.5 * Double(shownBytes) }

    public var hasUnknown: Bool { caveats.contains { if case .unknownForSome = $0 { true } else { false } } }

    /// - Parameters:
    ///   - items: the selection.
    ///   - trashSameVolume: whether items go to a Trash on the volume they live on (nil/false for permanent delete
    ///     or tool commands).
    ///   - localSnapshotsPresent: `tmutil listlocalsnapshots` found snapshots on the volume.
    public static func make(items: [ScanItem], trashSameVolume: Bool = false,
                            localSnapshotsPresent: Bool = false) -> ReclaimEstimate {
        var shown: Int64 = 0, frees: Int64 = 0, shared: Int64 = 0, unknown = 0
        for item in items {
            shown += item.sizeAllocated
            guard let r = item.reclaimableBytes else {
                frees += item.sizeAllocated          // not probed (small item): nothing to subtract
                continue
            }
            frees += min(r, item.sizeAllocated)
            shared += max(0, item.sizeAllocated - r)
            if item.reclaimIsEstimate { unknown += 1 }
        }
        var caveats: [Caveat] = []
        if trashSameVolume { caveats.append(.trashSameVolume) }
        if localSnapshotsPresent { caveats.append(.localSnapshotsPresent) }
        if shared > 0 { caveats.append(.clonesShared(bytes: shared)) }
        if unknown > 0 { caveats.append(.unknownForSome(count: unknown)) }
        return ReclaimEstimate(shownBytes: shown, freesAboutBytes: frees, caveats: caveats)
    }
}
