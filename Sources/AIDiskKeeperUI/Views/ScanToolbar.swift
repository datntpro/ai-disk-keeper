import SwiftUI

struct ScanToolbar: ToolbarContent {
    let scan: ScanViewModel
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if scan.isScanning {
                Button { scan.cancelScan() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(scan.phase == .cancelling)
                    .help("Stop scanning (⌘.)")
                    .accessibilityLabel("Stop scan")
            } else {
                Button { scan.startScan() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .help("Scan (⌘R)")
                    .accessibilityLabel("Scan")
            }
        }
    }
}
