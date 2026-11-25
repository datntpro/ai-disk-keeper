/// Shared by the status bar and the VoiceOver announcement so the two never drift apart.
func finishedAnnouncement(bytes: String, count: Int) -> String {
    loc("status.finished", "Scan finished: \(bytes) in \(count) items")
}
