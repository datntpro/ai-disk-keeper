import SwiftUI

struct ScanStatusBar: View {
    let scan: ScanViewModel

    var statusText: String {
        switch scan.phase {
        case .idle: return L10n.tr("status.ready", "Ready")
        case .starting: return L10n.tr("status.starting", "Starting…")
        case .scanning, .cancelling:
            let t = scan.totals.all
            let bytes = Formatting.bytes(t.allocatedBytes)
            var s = scan.phase == .cancelling
                ? L10n.tr("status.stopping", "Stopping… \(t.itemCount) items · \(bytes) found")
                : L10n.tr("status.scanning", "Scanning… \(t.itemCount) items · \(bytes) found")
            if let p = scan.progress, p.candidatesSized < p.candidatesFound {
                s += L10n.tr("status.sized", " · sized \(p.candidatesSized) of \(p.candidatesFound)")
            }
            return s
        case .finished:
            let t = scan.totals.all
            return L10n.finishedAnnouncement(bytes: Formatting.bytes(t.allocatedBytes), count: t.itemCount)
        case .cancelled: return L10n.tr("status.stopped", "Scan stopped. Results are partial.")
        case .failed(let m): return L10n.tr("status.failed", "Scan failed: \(m)")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if scan.isScanning { ProgressView().controlSize(.small) }
            Text(statusText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityValue(statusText)
            Spacer()
            if case .failed = scan.phase { Button(L10n.tr("action.tryAgain", "Try again")) { scan.startScan() } }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
