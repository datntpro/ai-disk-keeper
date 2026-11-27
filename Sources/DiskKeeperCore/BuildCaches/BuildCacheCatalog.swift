import Foundation

/// Which scan items the "Build caches" module lists, how it groups them, and the copyable hints that let a
/// tool clean its own cache. Hints are text only: Disk Keeper never runs `pnpm`, `tart`, `go` or `npm`.
public enum BuildCacheCatalog {
    public enum Family: String, CaseIterable, Sendable {
        case xcode, javascript, go, rust, jvm, swift, python, vms, other
    }

    /// Rule-id prefixes the module lists. `dev-caches.` and `build-caches.` are whole files; the `system.` entries are
    /// the package-manager caches that live in the shared system-junk rules.
    public static let rulePrefixes: [String] = [
        "dev-caches.", "build-caches.",
        "system.npm-cache", "system.pnpm-store-cache", "system.uv-cache", "system.pip-cache", "system.bun-cache",
    ]

    public static func lists(ruleID: String) -> Bool { rulePrefixes.contains { ruleID.hasPrefix($0) } }

    public static func family(ruleID: String) -> Family {
        switch ruleID {
        case _ where ruleID.hasPrefix("build-caches.xcode"), "dev-caches.xcode-archives", "dev-caches.device-support",
             "dev-caches.simulator-caches", "dev-caches.xcode-previews": .xcode
        case _ where ruleID.hasPrefix("build-caches.tart"): .vms
        case "build-caches.pnpm-store", "system.npm-cache", "system.pnpm-store-cache", "system.bun-cache",
             "dev-caches.yarn", "dev-caches.yarn-berry": .javascript
        case "dev-caches.go-build", "dev-caches.go-mod": .go
        case _ where ruleID.hasPrefix("dev-caches.cargo"): .rust
        case _ where ruleID.hasPrefix("dev-caches.gradle"): .jvm
        case "dev-caches.swiftpm", "dev-caches.cocoapods": .swift
        case "system.uv-cache", "system.pip-cache": .python
        default: .other
        }
    }

    public struct Hint: Sendable, Hashable {
        public let ruleIDs: [String]
        /// The exact text the copy button puts on the pasteboard.
        public let command: String
    }

    public static let hints: [Hint] = [
        Hint(ruleIDs: ["build-caches.pnpm-store", "system.pnpm-store-cache"], command: "pnpm store prune"),
        Hint(ruleIDs: ["build-caches.tart-oci"], command: "tart prune --entries=caches --older-than=7"),
        Hint(ruleIDs: ["build-caches.tart-vms"], command: "tart delete <name>"),
        Hint(ruleIDs: ["dev-caches.go-build"], command: "go clean -cache"),
        Hint(ruleIDs: ["system.npm-cache"], command: "npm cache verify"),
    ]

    /// Hints for the rules that have at least one item, in catalog order, without repeats.
    public static func hints(forRuleIDs present: Set<String>) -> [Hint] {
        hints.filter { hint in hint.ruleIDs.contains(where: present.contains) }
    }
}
