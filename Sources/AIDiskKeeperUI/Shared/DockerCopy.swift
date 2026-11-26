import DiskKeeperCore
import Foundation

/// Every Docker string. Names of images, containers and volumes are data and stay as docker reports them.
enum DockerCopy {
    static func explanation(ruleID: String) -> String? {
        switch ruleID {
        case DockerToolCommands.Rule.dangling:
            loc("docker.explain.dangling", "An untagged image left behind when a newer build replaced it. No container uses it. Docker removes it; nothing you need is lost.")
        case DockerToolCommands.Rule.unusedImage:
            loc("docker.explain.unused", "An image no container uses. Docker downloads or builds it again the next time you need it.")
        case DockerToolCommands.Rule.container:
            loc("docker.explain.container", "A stopped container. Removing it deletes files changed inside it and its logs. Volumes it used are kept.")
        case DockerToolCommands.Rule.anonymousVolume:
            loc("docker.explain.anonymousVolume", "An unnamed volume no container uses. Volumes can hold databases; check before removing. This can't be undone.")
        case DockerToolCommands.Rule.namedVolume:
            loc("docker.explain.namedVolume", "A named volume no container uses right now. It may hold a database or project data, so AI Disk Keeper won't remove it. If you're sure, run `docker volume rm <name>` in Terminal.")
        case DockerToolCommands.Rule.buildCache:
            loc("docker.explain.buildCache", "Build cache that no running build uses. Docker recreates it as needed; your next builds may be slower.")
        default: nil
        }
    }

    static var cardTitle: String { loc("docker.card.title", "Docker") }
    static func diskImage(_ onDisk: String, runtime: String) -> String {
        loc("docker.diskImage", "Docker keeps everything in one disk image (\(onDisk) on disk). Cleaning frees space inside it right away, but the file itself shrinks only when \(runtime) gives the space back. That can take a while or a restart. AI Disk Keeper never changes or deletes the disk image.")
    }
    static var diskImageWhy: String { loc("docker.diskImage.why", "Why doesn't the file shrink right away?") }
    static func diskImageSizes(_ onDisk: String, _ max: String) -> String {
        loc("docker.diskImage.sizes", "\(onDisk) on disk · \(max) max")
    }
    static func notRunning(_ runtime: String) -> String {
        loc("docker.notRunning", "\(runtime) isn't running. Start it, then scan again to see images, containers and volumes.")
    }
    static func timedOut(_ runtime: String, seconds: String) -> String {
        loc("docker.timedOut", "\(runtime) didn't respond within \(seconds) seconds. Try again later.")
    }
    static func running(_ runtime: String, _ version: String, state: String) -> String {
        loc("docker.running", "\(runtime) \(version) · \(state)")
    }
    static var stateRunning: String { loc("docker.state.running", "Running") }
    static var stateNotRunning: String { loc("docker.state.notRunning", "Not running") }
    static var stateTimedOut: String { loc("docker.state.timedOut", "Not responding") }
    static var checking: String { loc("docker.checking", "Checking Docker…") }
}

enum DockerTexts {
    static func text(for item: ScanItem) -> ScannerTexts.Text? {
        DockerCopy.explanation(ruleID: item.ruleID).map { .init(name: nil, explanation: $0) }
    }
}
