import SwiftUI

struct ScanToolbar: ToolbarContent {
    let scan: ScanViewModel
    let care: CareScanModel
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if care.isBusy || scan.isScanning {
                Button { if care.isBusy { care.stop() } else { scan.cancelScan() } } label: { Label(loc("action.stop", "Stop"), systemImage: "stop.fill") }
                    .disabled(scan.phase == .cancelling && !care.isBusy)
                    .help(loc("toolbar.stop.help", "Stop scanning (⌘.)"))
                    .accessibilityLabel(loc("toolbar.stop.a11y", "Stop scan"))
            } else {
                Button { care.start() } label: { Label(loc("action.scan", "Scan"), systemImage: "arrow.clockwise") }
                    .help(loc("toolbar.scan.help", "Scan (⌘R)"))
                    .accessibilityLabel(loc("action.scan", "Scan"))
            }
        }
    }
}
