import DiskKeeperCore
import SwiftUI

/// H6: "Shown X · frees about Y" copy. Information only: nothing here blocks or deselects a cleanup.
enum ReclaimCopy {
    static func freesAbout(_ n: Int64) -> String { loc("reclaim.freesAbout", "Frees about \(Formatting.bytes(n))") }
    static func shown(_ n: Int64) -> String { loc("reclaim.shown", "Shown \(Formatting.bytes(n))") }
    static var sharedWithClones: String { loc("reclaim.sharedWithClones", "Blocks shared with clones stay used") }
    static var sharedLinks: String { loc("reclaim.sharedLinks", "Files also linked from outside stay used") }
    static var returnsWhenTrashEmptied: String { loc("reclaim.trashReturns", "Space returns when you empty the Trash") }
    static var snapshotsKeepUsed: String {
        loc("reclaim.snapshots", "Local snapshots may keep this space used for a while")
    }
    static var mayFreeLess: String { loc("reclaim.mayFreeLess", "May free less") }

    static func caveatText(_ c: ReclaimEstimate.Caveat, linkedOutside: Bool = false) -> String {
        switch c {
        case .trashSameVolume: returnsWhenTrashEmptied
        case .localSnapshotsPresent: snapshotsKeepUsed
        case .clonesShared: linkedOutside ? sharedLinks : sharedWithClones
        case .unknownForSome: mayFreeLess
        }
    }

    /// "Shown 87 GB · Frees about 1.2 GB", or nil when there is nothing to add (equal and nothing uncertain).
    /// Caveats (including "May free less") are listed separately, once each.
    static func line(for e: ReclaimEstimate) -> String? {
        guard e.hasMeasured, e.freesAboutBytes < e.shownBytes || !e.caveats.isEmpty else { return nil }
        return "\(shown(e.shownBytes)) · \(freesAbout(e.freesAboutBytes))"
    }

    /// The caveats to list: all of them when something was measured, otherwise only "May free less" (a number that
    /// was never measured is not presented as a finding).
    static func visibleCaveats(_ e: ReclaimEstimate) -> [ReclaimEstimate.Caveat] {
        e.hasMeasured ? e.caveats : e.caveats.filter { if case .unknownForSome = $0 { true } else { false } }
    }

    /// The compact "frees ≈ Y" for a table row or module header; nil unless it is clearly smaller than shown.
    static func compact(for e: ReclaimEstimate) -> String? {
        e.isMuchSmaller ? freesAbout(e.freesAboutBytes) : nil
    }
}

/// Whether local snapshots may hold space on the data volume. Looked up at most once every few minutes; an
/// unreadable listing counts as "may hold" (the conservative answer).
actor ReclaimSnapshots {
    static let shared = ReclaimSnapshots()
    private var cached: (at: Date, value: Bool)?

    func mayHoldSpace() async -> Bool {
        if let c = cached, Date().timeIntervalSince(c.at) < 300 { return c.value }
        let listing = (try? await LocalSnapshotLister().list(volume: "/System/Volumes/Data")) ?? .unavailable(.timedOut)
        let v = ReclaimEstimate.snapshotsMayHoldSpace(listing)
        cached = (Date(), v)
        return v
    }
}

/// Review-sheet line: the estimate plus its caveats (trash, snapshots, clones, unknown).
struct ReclaimLine: View {
    let items: [ScanItem]
    let trashes: Bool
    @State private var snapshots = false

    var body: some View {
        let estimate = ReclaimEstimate.make(items: items, trashSameVolume: trashes, localSnapshotsPresent: snapshots)
        let linked = items.contains { $0.flags.contains(.sharedStorage) }
        let caveats = ReclaimCopy.visibleCaveats(estimate)
        let line = ReclaimCopy.line(for: estimate)
        Group {
            if line != nil || !caveats.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if let line {
                        Label(line, systemImage: estimate.isMuchSmaller ? "exclamationmark.circle" : "info.circle")
                            .font(estimate.isMuchSmaller ? .callout.weight(.semibold) : .callout)
                            .foregroundStyle(estimate.isMuchSmaller ? Color.adkAccent : Color.adkText2)
                    }
                    ForEach(Array(caveats.enumerated()), id: \.offset) { _, c in
                        Text(ReclaimCopy.caveatText(c, linkedOutside: linked)).font(.caption).foregroundStyle(.adkText3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { snapshots = await ReclaimSnapshots.shared.mayHoldSpace() }
    }
}
