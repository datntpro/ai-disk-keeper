import SwiftUI

struct ScanToolbar: ToolbarContent {
    let scan: ScanViewModel
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if scan.isScanning {
                Button { scan.cancelScan() } label: { Label(loc("action.stop", "Stop"), systemImage: "stop.fill") }
                    .disabled(scan.phase == .cancelling)
                    .help(loc("toolbar.stop.help", "Stop scanning (⌘.)"))
                    .accessibilityLabel(loc("toolbar.stop.a11y", "Stop scan"))
            } else {
                Button { scan.startScan() } label: { Label(loc("action.scan", "Scan"), systemImage: "arrow.clockwise") }
                    .help(loc("toolbar.scan.help", "Scan (⌘R)"))
                    .accessibilityLabel(loc("action.scan", "Scan"))
            }
        }
    }
}
