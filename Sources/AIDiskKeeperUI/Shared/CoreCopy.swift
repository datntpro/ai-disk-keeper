import DiskKeeperCore
import Foundation

// Wording for text that Core produces as stable codes. Core keeps its English `message` / `displayName` for the CLI,
// logs and the audit log; the UI words everything the user reads. Exhaustive switches mean a new Core case can't
// ship without a key here.

extension ItemCategory {
    var uiName: String {
        switch self {
        case .aiToolData: loc("category.aiToolData", "AI tool data")
        case .worktree: loc("category.worktree", "Worktrees")
        case .buildArtifact: loc("category.buildArtifact", "Build artifacts")
        case .modelWeights: loc("category.modelWeights", "Model weights")
        case .systemJunk: loc("category.systemJunk", "System junk")
        case .docker: loc("category.docker", "Docker")
        case .largeFile: loc("category.largeFile", "Large files")
        case .duplicate: loc("category.duplicate", "Duplicates")
        case .application: loc("category.application", "Applications")
        case .appLeftover: loc("category.appLeftover", "App leftovers")
        case .startupItem: loc("category.startupItem", "Startup items")
        }
    }
}

extension ToolID {
    /// Brand names are not translated; only the generic groups are.
    var uiName: String {
        switch rawValue {
        case "system": loc("tool.system", "System")
        case "files": loc("tool.files", "Your files")
        case "apps": loc("tool.apps", "Applications")
        default: knownDisplayName ?? rawValue
        }
    }
}

extension ScanWarning {
    /// The warning in the active language. Technical tails (errno text, rule ids, paths) stay verbatim.
    var uiMessage: String {
        guard let code else { return message }
        switch code {
        case .itemCapExceeded(let cap):
            return loc("warning.code.itemCap", "This rule found more than \(cap) items, so the rest were skipped.")
        case .pathError(let errno):
            switch errno {
            case EACCES: return loc("warning.code.pathDenied", "Couldn't read this location: permission denied.")
            case EPERM: return loc("warning.code.pathNotPermitted", "Couldn't read this location: macOS blocked it (Full Disk Access?).")
            case ENOTDIR: return loc("warning.code.pathNotFolder", "This location isn't a folder, or it's a symbolic link.")
            default: return loc("warning.code.pathError", "Couldn't read this location (\(String(cString: strerror(errno)))).")
            }
        case .ruleOverlap(let earlier):
            return loc("warning.code.ruleOverlap", "Overlaps items of \(earlier); the earlier rule wins.")
        case .cannotSize(let errno):
            let detail = errno.map { String(cString: strerror($0)) } ?? loc("warning.code.unknownError", "unknown error")
            return loc("warning.code.cannotSize", "Couldn't measure this item (\(detail)).")
        case .ruleFileInvalid:
            return loc("warning.code.ruleFile", "A rule file couldn't be used: \(message)")
        case .scannerFailed("care-history"):
            return loc("warning.code.careHistory", "Couldn't save the scan history. Growth won't be shown next time.")
        case .scannerFailed(let id):
            return loc("warning.code.scannerFailed", "The scanner \(id) failed and was skipped.")
        case .itemOverlap(let earlier):
            return loc("warning.code.itemOverlap", "Skipped: this item overlaps another one (\(earlier)).")
        case .appSkipped(let reason):
            switch reason {
            case .noInfoPlist: return loc("warning.code.appNoPlist", "Skipped: this app has no Info.plist.")
            case .damagedInfoPlist: return loc("warning.code.appDamagedPlist", "Skipped: this app's Info.plist is damaged.")
            case .noBundleID: return loc("warning.code.appNoBundleID", "Skipped: this app has no valid bundle identifier.")
            }
        case .sizeIncomplete:
            return loc("warning.code.sizeIncomplete", "Some files inside couldn't be read, so the size may be too low.")
        case .settingsUnreadable(let backup):
            if let backup {
                return loc("warning.code.settingsBackedUp",
                           "Your previous settings were unreadable and were backed up as \(backup). Default settings are in use.")
            }
            return loc("warning.code.settingsUnreadable", "Your previous settings were unreadable. Default settings are in use.")
        }
    }
}

enum CoreCopy {
    /// Why a path is protected, in the active language. `nil` ids fall back to `fallback` (the English reason).
    static func protectedWhy(id: String, fallback: String? = nil) -> String? {
        let text: String? = switch id {
        case "claude.code.account.config": loc("protected.why.claude.code.account.config", "Claude Code account/config")
        case "claude.code.settings": loc("protected.why.claude.code.settings", "Claude Code settings")
        case "claude.code.credentials": loc("protected.why.claude.code.credentials", "Claude Code credentials")
        case "claude.code.instructions": loc("protected.why.claude.code.instructions", "Claude Code instructions")
        case "claude.code.skills": loc("protected.why.claude.code.skills", "Claude Code skills")
        case "claude.code.agents": loc("protected.why.claude.code.agents", "Claude Code agents")
        case "claude.code.commands": loc("protected.why.claude.code.commands", "Claude Code commands")
        case "claude.code.hooks": loc("protected.why.claude.code.hooks", "Claude Code hooks")
        case "claude.code.output.styles": loc("protected.why.claude.code.output.styles", "Claude Code output styles")
        case "claude.code.keybindings": loc("protected.why.claude.code.keybindings", "Claude Code keybindings")
        case "claude.code.plugin.config": loc("protected.why.claude.code.plugin.config", "Claude Code plugin config")
        case "claude.code.plugin.registry": loc("protected.why.claude.code.plugin.registry", "Claude Code plugin registry")
        case "claude.code.auto.memory": loc("protected.why.claude.code.auto.memory", "Claude Code auto-memory")
        case "codex.credentials": loc("protected.why.codex.credentials", "Codex credentials")
        case "codex.config": loc("protected.why.codex.config", "Codex config")
        case "codex.instructions": loc("protected.why.codex.instructions", "Codex instructions")
        case "gemini.credentials": loc("protected.why.gemini.credentials", "Gemini credentials")
        case "gemini.settings": loc("protected.why.gemini.settings", "Gemini settings")
        case "gemini.accounts": loc("protected.why.gemini.accounts", "Gemini accounts")
        case "gemini.instructions": loc("protected.why.gemini.instructions", "Gemini instructions")
        case "cursor.mcp.config": loc("protected.why.cursor.mcp.config", "Cursor MCP config")
        case "cursor.settings": loc("protected.why.cursor.settings", "Cursor settings")
        case "cursor.keybindings": loc("protected.why.cursor.keybindings", "Cursor keybindings")
        case "cursor.snippets": loc("protected.why.cursor.snippets", "Cursor snippets")
        case "copilot.credentials": loc("protected.why.copilot.credentials", "Copilot credentials")
        case "credentials": loc("protected.why.credentials", "credentials")
        case "docker.credentials": loc("protected.why.docker.credentials", "Docker credentials")
        case "github.cli.credentials": loc("protected.why.github.cli.credentials", "GitHub CLI credentials")
        case "google.cloud.credentials": loc("protected.why.google.cloud.credentials", "Google Cloud credentials")
        case "shell.config": loc("protected.why.shell.config", "shell config")
        case "shell.history": loc("protected.why.shell.history", "shell history")
        case "git.config": loc("protected.why.git.config", "git config")
        case "npm.credentials": loc("protected.why.npm.credentials", "npm credentials")
        case "pypi.credentials": loc("protected.why.pypi.credentials", "PyPI credentials")
        case "password.store": loc("protected.why.password.store", "password store")
        case "keychain": loc("protected.why.keychain", "Keychain")
        case "app.preferences": loc("protected.why.app.preferences", "app preferences")
        case "icloud.drive": loc("protected.why.icloud.drive", "iCloud Drive")
        case "cloud.storage": loc("protected.why.cloud.storage", "cloud storage")
        case "mail": loc("protected.why.mail", "Mail")
        case "messages": loc("protected.why.messages", "Messages")
        case "trash": loc("protected.why.trash", "Trash")
        case "docker.disk.image": loc("protected.why.docker.disk.image", "Docker disk image")
        case "claude.desktop.mcp.config": loc("protected.why.claude.desktop.mcp.config", "Claude desktop MCP config")
        case "cargo.credentials": loc("protected.why.cargo.credentials", "Cargo credentials")
        case "1password.cli": loc("protected.why.1password.cli", "1Password CLI")
        case "vault.token": loc("protected.why.vault.token", "Vault token")
        case "terraform.credentials": loc("protected.why.terraform.credentials", "Terraform credentials")
        case "rubygems.credentials": loc("protected.why.rubygems.credentials", "RubyGems credentials")
        case "maven.credentials": loc("protected.why.maven.credentials", "Maven credentials")
        case "browser.passwords": loc("protected.why.browser.passwords", "browser passwords")
        case "browser.cookies": loc("protected.why.browser.cookies", "browser cookies")
        case "browser.password.key": loc("protected.why.browser.password.key", "browser password key")
        case "ssh.agent.socket.directory": loc("protected.why.ssh.agent.socket.directory", "SSH agent socket directory")
        case "ai.disk.keeper.settings.audit.log.and.rules": loc("protected.why.ai.disk.keeper.settings.audit.log.and.rules", "AI Disk Keeper settings, audit log and rules")
        case "environment.secrets": loc("protected.why.environment.secrets", "environment secrets")
        case "private.key": loc("protected.why.private.key", "private key")
        case "certificate.bundle": loc("protected.why.certificate.bundle", "certificate bundle")
        case "ssh.key": loc("protected.why.ssh.key", "SSH key")
        case "agent.instructions": loc("protected.why.agent.instructions", "agent instructions")
        case "git.repository.data": loc("protected.why.git.repository.data", "git repository data")
        case "photos.library": loc("protected.why.photos.library", "Photos library")
        case "iphoto.library": loc("protected.why.iphoto.library", "iPhoto library")
        case "music.library": loc("protected.why.music.library", "Music library")
        case "tv.library": loc("protected.why.tv.library", "TV library")
        case "aperture.library": loc("protected.why.aperture.library", "Aperture library")
        case "imovie.library": loc("protected.why.imovie.library", "iMovie library")
        case "final.cut.pro.library": loc("protected.why.final.cut.pro.library", "Final Cut Pro library")
        case "system": loc("protected.why.system", "system")
        case "protected.by.rule": loc("protected.why.protected.by.rule", "protected by rule")
        case "filesystem.root": loc("protected.why.filesystem.root", "filesystem root")
        case "allowed.root": loc("protected.why.allowed.root", "allowed root")
        default: nil
        }
        return text ?? fallback
    }

    /// One sentence for a denied path. `pattern` / `whyID` come from the protected-path table.
    static func denial(reason: PathDenial.Reason, pattern: String?, whyID: String?) -> String {
        let base: String = switch reason {
        case .invalidPath: loc("denial.invalidPath", "This isn't a valid absolute path.")
        case .parentTraversal: loc("denial.parentTraversal", "Paths containing “..” are never accepted.")
        case .unresolvable: loc("denial.unresolvable", "This location can't be resolved safely.")
        case .systemLocation: loc("denial.systemLocation", "System location: it is never touched.")
        case .outsideAllowedRoots: loc("denial.outsideAllowedRoots", "Outside your home folder and temporary folders.")
        case .protectedLocation: loc("denial.protectedLocation", "Protected location: it is a container, never an item.")
        case .protectedPath: loc("denial.protectedPath", "Protected: this is never cleaned.")
        case .containsProtectedPath: loc("denial.containsProtectedPath", "Contains protected data, so it can't be an item.")
        case .protectedName: loc("denial.protectedName", "Protected name: it may hold secrets or instructions.")
        }
        guard let pattern else { return base }
        if let whyID, let why = protectedWhy(id: whyID) {
            return loc("denial.matchedWhy", "\(base) Matches \(pattern) (\(why)).")
        }
        return loc("denial.matched", "\(base) Matches \(pattern).")
    }
}
