import SwiftUI

struct ScanStatusBar: View {
    let scan: ScanViewModel

    var statusText: String {
        switch scan.phase {
        case .idle: return "Ready"
        case .starting: return "Starting…"
        case .scanning, .cancelling:
            let t = scan.totals.all
            var s = "\(scan.phase == .cancelling ? "Stopping… " : "Scanning… ")\(t.itemCount) items · \(Formatting.bytes(t.allocatedBytes)) found"
            if let p = scan.progress, p.candidatesSized < p.candidatesFound {
                s += " · sized \(p.candidatesSized) of \(p.candidatesFound)"
            }
            return s
        case .finished:
            let t = scan.totals.all
            return "Scan finished: \(Formatting.bytes(t.allocatedBytes)) in \(t.itemCount) items"
        case .cancelled: return "Scan stopped. Results are partial."
        case .failed(let m): return "Scan failed: \(m)"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if scan.isScanning { ProgressView().controlSize(.small) }
            Text(statusText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityValue(statusText)
            Spacer()
            if case .failed = scan.phase { Button("Try again") { scan.startScan() } }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
