# AI Disk Keeper

A native macOS app (SwiftUI, macOS 14+) that **finds, explains and safely cleans** disk usage
created by AI coding tools and their side effects:

- AI tool data — Claude Code (`~/.claude`), Claude desktop, Cursor, Codex, Gemini / Antigravity,
  Kiro, Copilot, Windsurf, Aider, Continue, Orca workspaces…
- Agent worktrees and stray git worktrees, classified by git state (merged & clean vs. dirty/unpushed)
- Per-worktree build artifacts and dependency dirs (`node_modules`, `.venv`, `target/`, `.next`, `DerivedData`…)
- Local model weights (Ollama, LM Studio, Hugging Face) — reviewed per model, never bulk-deleted
- System junk those tools leave behind (logs, crash reports, caches, scratch dirs, Docker data)

Scanning is **read-only by default**. Every item gets a risk tier — **Safe / Review / Keep** — with
a plain-language explanation. Cleanup moves to the Trash by default, always shows a dry-run
preview first, writes an audit log, and never touches credentials, auth or config files.

> Status: scaffold only. See [docs/PLAN.md](docs/PLAN.md) for the plan, architecture and milestones.

## Build & test

Requires macOS 14+ and **Xcode 16+** (full Xcode is needed for `swift test`; Command Line Tools alone
can `swift build` but have no XCTest).

```sh
swift build            # build core library + app executable
swift test             # run XCTest suite
swift run AIDiskKeeper # launch the (scaffold) app
```

You can also open `Package.swift` in Xcode.

## Layout

```
Package.swift
Sources/DiskKeeperCore/   # scan engine, scanner rules, safety policy, cleanup engine (no UI)
Sources/AIDiskKeeper/     # SwiftUI app (window + menu bar)
Tests/DiskKeeperCoreTests/
docs/PLAN.md
```

CI (`.github/workflows/ci.yml`) builds and tests on a GitHub-hosted macOS runner for every PR.
