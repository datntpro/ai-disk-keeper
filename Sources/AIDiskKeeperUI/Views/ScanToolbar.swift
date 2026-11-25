import SwiftUI

struct ScanToolbar: ToolbarContent {
    let scan: ScanViewModel
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if scan.isScanning {
                Button { scan.cancelScan() } label: { Label(L10n.tr("action.stop", "Stop"), systemImage: "stop.fill") }
                    .disabled(scan.phase == .cancelling)
                    .help(L10n.tr("toolbar.stop.help", "Stop scanning (⌘.)"))
                    .accessibilityLabel(L10n.tr("toolbar.stop.a11y", "Stop scan"))
            } else {
                Button { scan.startScan() } label: { Label(L10n.tr("action.scan", "Scan"), systemImage: "arrow.clockwise") }
                    .help(L10n.tr("toolbar.scan.help", "Scan (⌘R)"))
                    .accessibilityLabel(L10n.tr("action.scan", "Scan"))
            }
        }
    }
}
