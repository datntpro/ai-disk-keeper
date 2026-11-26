import SwiftUI

struct ScanStatusBar: View {
    let scan: ScanViewModel
    var care: CareScanModel?

    /// While a Care Scan runs or has run, the status bar speaks for it (its total), not for the rule stage inside it.
    @MainActor static func careStatusText(_ care: CareScanModel) -> String? {
        switch care.phase {
        case .before: nil
        case .scanning: OverviewCopy.found(Formatting.bytes(care.foundBytes))
        case .stopped: loc("status.stopped", "Scan stopped. Results are partial.")
        case .results:
            OverviewCopy.finishedAnnouncement(safe: Formatting.bytes(care.totals?.safeBytes ?? 0),
                                              review: Formatting.bytes(care.totals?.reviewBytes ?? 0))
        }
    }

    var statusText: String {
        if let care, let text = Self.careStatusText(care) { return text }
        switch scan.phase {
        case .idle: return loc("status.ready", "Ready")
        case .starting: return loc("status.starting", "Starting…")
        case .scanning, .cancelling:
            let t = scan.totals.all
            let bytes = Formatting.bytes(t.allocatedBytes)
            var s = scan.phase == .cancelling
                ? loc("status.stopping", "Stopping… \(t.itemCount) items · \(bytes) found")
                : loc("status.scanning", "Scanning… \(t.itemCount) items · \(bytes) found")
            if let p = scan.progress, p.candidatesSized < p.candidatesFound {
                s += loc("status.sized", " · sized \(p.candidatesSized) of \(p.candidatesFound)")
            }
            return s
        case .finished:
            let t = scan.totals.all
            return finishedAnnouncement(bytes: Formatting.bytes(t.allocatedBytes), count: t.itemCount)
        case .cancelled: return loc("status.stopped", "Scan stopped. Results are partial.")
        case .failed(let m): return loc("status.failed", "Scan failed: \(m)")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if scan.isScanning || care?.phase == .scanning { ProgressView().controlSize(.small) }
            Text(statusText).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityValue(statusText)
            Spacer()
            if case .failed = scan.phase { Button(loc("action.tryAgain", "Try again")) { scan.startScan() } }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
