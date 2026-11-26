import DiskKeeperCore
import Foundation

/// Every user-visible string of the Large & Old screen.
enum LargeOldCopy {
    static var title: String { loc("largeOld.title", "Large & Old Files") }
    static var subtitle: String { loc("largeOld.subtitle", "Your files — always Review, never Safe") }
    static var search: String { loc("largeOld.search", "Name or path") }
    static var filterNote: String { loc("largeOld.filter.note", "Skips iCloud-only files, Photos & Music libraries") }
    static var filterNoteMore: String {
        loc("largeOld.filter.noteMore", "Also skips ~/Library and hidden folders: AI Workspace and System Junk handle those with tool-aware cleanup. iCloud-only files are never downloaded.")
    }
    static var quickLookHint: String { loc("largeOld.quickLookHint", "Quick Look with Space") }
    static var reviewAction: String { loc("largeOld.action.review", "Review cleanup…") }
    static var quickLook: String { loc("largeOld.action.quickLook", "Quick Look") }
    static var copyPath: String { loc("largeOld.action.copyPath", "Copy path") }
    static var shared: String { loc("largeOld.shared", "shared storage — frees little") }
    static var sharedHelp: String { loc("largeOld.shared.help", "This file shares its storage with another file, so moving it to the Trash would free little or nothing.") }
    static var mountedImage: String { loc("largeOld.mounted", "Mounted disk image: eject it first") }
    static var mountedNote: String {
        loc("largeOld.inspector.mounted", "Keep: this disk image is attached right now. Eject it in Finder first; then it can be reviewed like any other file.")
    }
    static var hintInstalled: String { loc("largeOld.hint.installed", "app already installed") }
    static var emptyTitle: String { loc("largeOld.empty.title", "No large, old files") }
    static var showAll: String { loc("largeOld.empty.showAll", "Show all sizes") }
    static var analysing: String { loc("largeOld.analysing", "Looking for large, old files…") }
    static var analysingTitle: String { loc("largeOld.analysing.title", "Analysing") }
    static var failedTitle: String { loc("largeOld.failed.title", "Couldn't analyse your files") }
    static var incomplete: String { loc("largeOld.incomplete", "The index is incomplete, so some files may be missing.") }
    static var inspectorEmpty: String { loc("largeOld.inspector.empty", "Select a file to see why it's here.") }
    static var tierNote: String { loc("largeOld.inspector.tier", "Always Review: this is your own file, so you decide.") }
    static var shownInHome: String { loc("largeOld.folder.home", "Home") }

    static func column(_ c: Column) -> String {
        switch c {
        case .file: loc("largeOld.column.file", "File")
        case .kind: loc("largeOld.column.kind", "Kind")
        case .lastOpened: loc("largeOld.column.lastOpened", "Last opened")
        case .size: loc("largeOld.column.size", "Size")
        }
    }
    enum Column { case file, kind, lastOpened, size }

    static func kindPlural(_ k: LargeFileKind) -> String {
        switch k {
        case .archive: loc("largeOld.kind.archive", "Archives")
        case .diskImageOrInstaller: loc("largeOld.kind.diskImage", "Disk images & installers")
        case .video: loc("largeOld.kind.video", "Videos")
        case .vmImage: loc("largeOld.kind.vm", "VM & simulator images")
        case .other: loc("largeOld.kind.other", "Other")
        }
    }

    static func kindOne(_ k: LargeFileKind) -> String {
        switch k {
        case .archive: loc("largeOld.kind.archive.one", "Archive")
        case .diskImageOrInstaller: loc("largeOld.kind.diskImage.one", "Disk image")
        case .video: loc("largeOld.kind.video.one", "Video")
        case .vmImage: loc("largeOld.kind.vm.one", "VM image")
        case .other: loc("largeOld.kind.other.one", "Other")
        }
    }

    static func count(_ n: Int) -> String {
        n == 1 ? loc("largeOld.count.one", "1 file") : loc("largeOld.count.many", "\(Formatting.count(n)) files")
    }

    static func size(_ t: SizeThreshold) -> String { Formatting.bytes(t.bytes) }

    static func period(_ a: AgeThreshold) -> String {
        switch a {
        case .any: loc("largeOld.filter.ageAny", "Any age")
        case .m1: loc("largeOld.period.1m", "1 month")
        case .m3: loc("largeOld.period.3m", "3 months")
        case .m6: loc("largeOld.period.6m", "6 months")
        case .y1: loc("largeOld.period.1y", "1 year")
        case .y2: loc("largeOld.period.2y", "2 years")
        }
    }

    static func sizeFilter(_ t: SizeThreshold) -> String { loc("largeOld.filter.size", "Bigger than \(size(t))") }

    static func ageFilter(_ a: AgeThreshold) -> String {
        a == .any ? period(.any) : loc("largeOld.filter.age", "Not opened for \(period(a))")
    }

    static func folderFilter(_ name: String) -> String { loc("largeOld.filter.folder", "In \(name)") }

    static func sourceLabel(_ s: LastOpenedSource) -> String {
        switch s {
        case .spotlight: loc("largeOld.source.spotlight", "Last opened (Spotlight)")
        case .accessed: loc("largeOld.source.accessed", "Last accessed")
        case .modified: loc("largeOld.source.modified", "Last modified")
        }
    }

    static func sourceSymbol(_ s: LastOpenedSource) -> String {
        switch s {
        case .spotlight: "magnifyingglass"
        case .accessed: "eye"
        case .modified: "pencil"
        }
    }

    static func lastOpened(_ f: LargeFile, now: Date) -> String { Formatting.relative(f.lastOpened, now: now) }

    static func lastOpenedA11y(_ f: LargeFile, now: Date) -> String {
        loc("largeOld.lastOpened.a11y", "\(sourceLabel(f.lastOpenedSource)): \(lastOpened(f, now: now))")
    }

    static func installedNamed(_ app: String) -> String { loc("largeOld.hint.installedNamed", "\(app) is already installed") }

    static func emptyBody(_ size: SizeThreshold, _ age: AgeThreshold) -> String {
        loc("largeOld.empty.body", "Nothing bigger than \(Self.size(size)) that you haven't opened in \(period(age)).")
    }

    static func selectedCount(_ n: Int) -> String { count(n) }

    /// "Last opened 14 months ago. Moving it to the Trash frees up to 9 GB; you can put it back from the Trash."
    static func explanation(_ f: LargeFile, now: Date) -> String {
        if f.isMountedImage { return mountedImage }
        if f.linkCount > 1 || f.sharesAllStorage {
            return loc("largeOld.explain.shared", "This file shares all of its storage with another file, so moving it to the Trash frees almost nothing.")
        }
        let bytes = Formatting.bytes(f.reclaimableBytes ?? f.allocatedBytes)
        var text = loc("largeOld.explain.base", "Last opened \(lastOpened(f, now: now)). Moving it to the Trash frees up to \(bytes); you can put it back from the Trash.")
        if let app = f.installedAppMatch {
            text += " " + loc("largeOld.explain.installer", "The app it installs (\(app)) is already in Applications.")
        }
        return text
    }
}
