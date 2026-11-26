import AppKit
import Quartz

/// Shows the system Quick Look panel for one file. Read-only; the panel is owned by AppKit.
@MainActor
final class DuplicateQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = DuplicateQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
