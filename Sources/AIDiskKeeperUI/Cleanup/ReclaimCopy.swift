import DiskKeeperCore
import SwiftUI

/// H6: "Shown X · frees about Y" copy. Information only: nothing here blocks or deselects a cleanup.
enum ReclaimCopy {
    static func freesAbout(_ n: Int64) -> String { loc("reclaim.freesAbout", "Frees about \(Formatting.bytes(n))") }
    static func shown(_ n: Int64) -> String { loc("reclaim.shown", "Shown \(Formatting.bytes(n))") }
    static var sharedWithClones: String { loc("reclaim.sharedWithClones", "Blocks shared with clones stay used") }
    static var returnsWhenTrashEmptied: String { loc("reclaim.trashReturns", "Space returns when you empty the Trash") }
    static var snapshotsKeepUsed: String {
        loc("reclaim.snapshots", "Local snapshots may keep this space used for a while")
    }
    static var mayFreeLess: String { loc("reclaim.mayFreeLess", "May free less") }

    static func caveatText(_ c: ReclaimEstimate.Caveat) -> String {
        switch c {
        case .trashSameVolume: returnsWhenTrashEmptied
        case .localSnapshotsPresent: snapshotsKeepUsed
        case .clonesShared: sharedWithClones
        case .unknownForSome: mayFreeLess
        }
    }

    /// "Shown 87 GB · frees about 1.2 GB", or nil when there is nothing to add (frees about equals shown and
    /// nothing is uncertain).
    static func line(for e: ReclaimEstimate) -> String? {
        let differs = e.freesAboutBytes < e.shownBytes
        guard differs || e.hasUnknown else { return nil }
        let base = "\(shown(e.shownBytes)) · \(freesAbout(e.freesAboutBytes))"
        return e.hasUnknown && !differs ? "\(base) · \(mayFreeLess)" : base
    }
}

/// Review-sheet and header line.
struct ReclaimLine: View {
    let estimate: ReclaimEstimate

    var body: some View {
        if let line = ReclaimCopy.line(for: estimate) {
            VStack(alignment: .leading, spacing: 2) {
                Label(line, systemImage: estimate.isMuchSmaller ? "exclamationmark.circle" : "info.circle")
                    .font(estimate.isMuchSmaller ? .callout.weight(.semibold) : .callout)
                    .foregroundStyle(estimate.isMuchSmaller ? Color.adkAccent : Color.adkText2)
                ForEach(Array(estimate.caveats.enumerated()), id: \.offset) { _, c in
                    Text(ReclaimCopy.caveatText(c)).font(.caption).foregroundStyle(.adkText3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
