# AI Disk Keeper — Plan

Native macOS app (SwiftUI, macOS 14+) that **finds, explains and safely cleans** disk usage created
by AI coding tools and their side effects. This document is the source of truth for scope,
architecture, the safety model and the milestone/subtask breakdown. Each subtask is tracked as a
GitHub issue (see [§9](#9-subtasks)); tracking issue: #28.

## 1. Problem

Developers who code with AI agents accumulate disk usage that generic cleaners don't understand:

| Source | Example on a real dev Mac (measured 2026-11) |
|---|---|
| Claude desktop VM bundles / bundled Claude Code | `~/Library/Application Support/Claude/vm_bundles` **11 GB**, `claude-code` 685 MB |
| Claude Code CLI data | `~/.claude` 103 MB (`projects/` 65 MB of session transcripts, `plugins/` 30 MB) |
| Agent worktrees | `~/orca/workspaces` 163 MB (grows with every parallel agent × `node_modules`) |
| Other AI tools | `~/.kiro` 1.1 GB, `~/.gemini` (Antigravity), Kiro / Antigravity app support |
| Local model weights | `~/.ollama/models` 3.6 GB, `~/.cache/huggingface` 464 MB |
| Docker | `~/Library/Containers/com.docker.docker` **34 GB** |

Each agent session spawns worktrees, reinstalls dependencies per worktree, writes transcripts,
snapshots, logs and temp dirs, and pulls models or containers. Nothing tells the user what is safe
to remove — especially for worktrees, where deleting the wrong one loses uncommitted work.

## 2. Goals

1. **Find** disk usage from AI tools and their side effects in one read-only scan:
   AI tool data, agent/stray git worktrees, per-worktree build artifacts & dependency dirs,
   local model weights, and system junk (logs, crash reports, caches, temp/scratchpads, Docker).
2. **Explain** every item: which tool/project it belongs to, what it is, what you lose by
   deleting it, and a risk tier — **Safe / Review / Keep**.
3. **Clean safely**: dry-run preview first, move to Trash by default, audit log, never touch
   credentials/config/auth, re-validate right before acting, git-state-aware for worktrees.
4. **Break down** usage per tool and per project (a repo's worktrees + artifacts + sessions).
5. **Stay on top of it**: optional scheduled scan + notification, menu bar summary.
6. Native, fast, private: no network, no telemetry, no helper daemons with root.

## 3. Non-goals

- General-purpose Mac cleaning (mail attachments, photos, app uninstalling, "speed up your Mac").
- Duplicate-file finding or a full disk visualizer (DaisyDisk/GrandPerspective territory).
- Running with root / privileged helpers, or cleaning other users' files.
- Deleting anything automatically. Scheduled scans only notify.
- Managing AI tool settings, accounts or subscriptions.
- Windows/Linux (core is kept UI-free so a CLI could be added later, but not planned).
- Mac App Store sandboxed build in v1 (needs broad `~` access; see §6.6).

## 4. Competitive landscape & differentiators

| Tool | What it is | Gap we fill |
|---|---|---|
| [ClearDisk](https://alternativeto.net/software/cleardisk/about) | Generic Mac cleaner: caches, downloads, trash | No AI-tool or git awareness |
| [SpaceWise](https://www.producthunt.com/products/spacewise-2) | Native dev storage cleaner: Docker, DerivedData, dead `node_modules`, AI weights | Not aware of AI-tool session data or agent worktrees; no git-state safety |
| DevCleaner for Xcode | Xcode caches only (DerivedData, Archives, Device Support) | Single ecosystem |
| Harbofly | Mac cleaner (couldn't verify current feature set) | — |
| [agent-gc](https://github.com/williamjeong2/agent-gc) | Rust TUI: agent worktrees, duplicate deps, build artifacts, dry-run | Terminal only; no AI-tool data, models or Docker; no native UI / scheduling |
| [VibeHauler](https://github.com/zerob13/VibeHauler) | CLI: AI agent client data (sessions, caches, logs), Trash/quarantine + manifest | No worktree/git awareness, artifacts, models; CLI |
| [claude-code-cleaner](https://github.com/garrickz2/claude-code-cleaner) | TUI for `~/.claude` only | Single tool |
| TidyBug | (couldn't verify; reported as a Mac tidy utility) | — |
| Others seen: aiclean, cc-cleaner, DiskTidy, OpenClearn | Mostly CLI scripts for one or a few AI tools | Fragmented |

**Our differentiators (must be visible in the product, not just the README):**

1. **AI-tool + worktree awareness in one native app** — AI tool data, agent worktrees, their
   per-worktree `node_modules`/`.venv`/`target`, models, Docker and junk, attributed to the tool
   and the project that created them.
2. **Git-state-aware safety** — a worktree is only Safe when merged, clean, with no stash and no
   unpushed commits; anything else is Keep/Review with the exact reason ("3 uncommitted files,
   2 commits not pushed").
3. **Explain-first UX** — every item carries an explanation and tier; Review items can never be
   bulk-selected; models are always per-model review.
4. **Safety by construction** — hard-coded protected-path guard (credentials/config/auth),
   re-validation at cleanup time, in-use detection, Trash by default, audit log.
5. **Data-driven rules** — new AI tools are a JSON file, not a release; users can add their own.

## 5. Architecture

```
┌──────────────────────── AIDiskKeeper (SwiftUI app target) ────────────────────────┐
│  Main window (NavigationSplitView)   Menu bar extra   Settings   Onboarding        │
│        │ @Observable view models (MainActor) — no FS work on main thread          │
└────────┼───────────────────────────────────────────────────────────────────────────┘
         ▼
┌──────────────────────── DiskKeeperCore (library, no UI) ──────────────────────────┐
│ Rules       RuleLoader ── bundled Resources/Rules/*.json + user rules dir          │
│ Scan        ScanEngine (actor) ── Scanner protocol ──┬─ RuleScanner (JSON rules)    │
│             AsyncStream<ScanEvent>, TaskGroup,        ├─ WorktreeScanner (Git)      │
│             cancellation, bounded concurrency         ├─ ArtifactScanner            │
│                                                       ├─ ModelScanner (Ollama/HF/LMS)│
│                                                       └─ DockerScanner              │
│ FS          FileSizer (allocated bytes, hardlink dedupe, no symlink follow)         │
│ Git         GitInspector (/usr/bin/git, GIT_OPTIONAL_LOCKS=0, timeouts)             │
│ Safety      ProtectedPaths guard · InUseDetector · tier policy                      │
│ Cleanup     CleanupEngine: plan (dry run) → re-validate → Trash / tool CLI → audit  │
│ Model       ScanItem, RiskTier, ItemCategory, ToolID, ScanResult, CleanupPlan       │
│ Persistence Settings, scan cache, audit.jsonl (~/Library/Application Support/…)    │
└────────────────────────────────────────────────────────────────────────────────────┘
```

- **Build system:** Swift Package (`Package.swift`) — `swift build` / `swift test` from the CLI and
  CI; open in Xcode for UI work. An `.app` bundle is produced by `scripts/make-app.sh` (T12).
  No third-party dependencies in v1.
- **Concurrency:** Swift 6 strict concurrency. `ScanEngine` is an actor; sizing runs in a
  bounded `TaskGroup`; UI consumes `AsyncStream<ScanEvent>`; cancellation propagates via
  `Task.cancel()`.
- **Read-only by default:** scanners get a read-only FS facade; only `CleanupEngine` can mutate,
  and only from an explicit, user-confirmed `CleanupPlan`.

### 5.1 Module layout

```
Package.swift
Sources/
  DiskKeeperCore/
    Model/        ScanItem.swift, RiskTier.swift, ItemCategory.swift, ToolID.swift, ScanResult.swift
    FS/           FileSizer.swift, PathTemplate.swift
    Rules/        ScannerRule.swift, RuleLoader.swift, RuleValidator.swift, RuleScanner.swift
    Scan/         ScanEngine.swift, Scanner.swift, ScanEvent.swift
    Scanners/     WorktreeScanner.swift, ArtifactScanner.swift, OllamaScanner.swift,
                  HuggingFaceScanner.swift, LMStudioScanner.swift, DockerScanner.swift
    Git/          GitInspector.swift, GitState.swift, ProcessRunner.swift
    Safety/       ProtectedPaths.swift, InUseDetector.swift
    Cleanup/      CleanupEngine.swift, CleanupPlan.swift, TrashAdapter.swift, AuditLog.swift
    Persistence/  SettingsStore.swift, ScanCache.swift
    Resources/Rules/  claude-code.json, claude-desktop.json, cursor.json, codex.json, gemini.json,
                      kiro.json, windsurf.json, copilot.json, aider.json, continue.json, orca.json,
                      system-junk.json
  AIDiskKeeper/
    AIDiskKeeperApp.swift, Views/…, ViewModels/…, MenuBar/…, Settings/…
Tests/
  DiskKeeperCoreTests/   (+ Fixtures/ fake HOME trees, git repo builders, recorded JSON)
scripts/make-app.sh
docs/PLAN.md, docs/rules.md, docs/PERF.md
```

## 6. Scanner rule format

Rules are JSON files (one per tool) loaded from the app bundle and, optionally, from
`~/Library/Application Support/AIDiskKeeper/Rules`. Things that need logic (git state, Ollama
manifests, Docker) are Swift `Scanner`s that still emit the same `ScanItem`s.

```jsonc
{
  "schemaVersion": 1,
  "tool": { "id": "claude-code", "name": "Claude Code", "docs": "https://docs.claude.com/…" },
  "protect": ["~/.claude.json", "~/.claude/settings*.json", "~/.claude/.credentials.json",
              "~/.claude/skills/**", "~/.claude/agents/**", "~/.claude/commands/**"],
  "rules": [
    {
      "id": "claude-code.projects",
      "title": "Session transcripts",
      "category": "aiToolData",
      "paths": ["~/.claude/projects"],
      "match": { "kind": "children", "glob": "*", "type": "directory" },
      "project": { "from": "claudeProjectDirName" },
      "tier": "review",
      "tierWhen": [
        { "if": { "newerThanDays": 7 }, "tier": "keep" },
        { "if": { "olderThanDays": 30 }, "tier": "safe" }
      ],
      "explanation": "Conversation history for one project. Deleting it removes `claude --resume` history for that project; it does not affect your code.",
      "cleanup": { "method": "trash" }
    },
    {
      "id": "claude-desktop.cache",
      "title": "Claude desktop web caches",
      "category": "aiToolData",
      "paths": ["$APP_SUPPORT/Claude/Cache", "$APP_SUPPORT/Claude/Code Cache"],
      "match": { "kind": "self" },
      "tier": "safe",
      "explanation": "Chromium HTTP/code caches; rebuilt automatically.",
      "cleanup": { "method": "trash", "requiresAppQuit": "com.anthropic.claudefordesktop" }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `paths` | Templates: `~`, `$HOME`, `$TMPDIR`, `$APP_SUPPORT`, `$CACHES`, `$LOGS`, env vars (`$HF_HOME`) with fallbacks |
| `match.kind` | `self` (the path is one item), `children` (each child matching `glob`/`type` is an item), `find` (recursive with `name` + required `marker` sibling, `maxDepth`, prune on match) |
| `tier` / `tierWhen` | Default tier; first matching condition wins. Conditions: `olderThanDays`, `newerThanDays`, `sizeOverMB`, `markerExists`, `gitState` (code scanners) |
| `protect` | Extra tool-specific protected globs, **added** to the global denylist (never subtracted) |
| `cleanup.method` | `trash` (default), `toolCommand` (e.g. `ollama rm`, `docker image rm`), `none` (report only) |
| `cleanup.requiresAppQuit` | Bundle id that must not be running before cleanup |

Validation (T03) rejects unknown keys, rules resolving outside `~`/`$TMPDIR`, and any rule whose
paths intersect protected paths. Full reference: `docs/rules.md` (T03).

## 7. Safety model

1. **Read-only scan.** Scanners cannot write. Git calls use `GIT_OPTIONAL_LOCKS=0`, no `fetch`.
2. **Risk tiers.**
   - **Safe** — regenerable or disposable with no user value (caches, merged-and-clean worktrees,
     old transcripts past the retention threshold). Can be selected with "Select all Safe".
   - **Review** — probably disposable but costs something (reinstall time, history, a model
     download). Must be ticked individually; never bulk-selectable. All model weights are Review.
   - **Keep** — shown for visibility, not selectable: dirty/unpushed/stashed worktrees, recently
     modified data (< 7 days for sessions, < 24 h for temp), in-use items.
3. **Protected paths** (T04) — a hard-coded, non-overridable denylist for credentials, auth and
   config (`~/.claude.json`, `~/.claude/settings*.json`, `.credentials.json`, `~/.codex/auth.json`,
   `~/.gemini/oauth_creds.json`, `~/.ssh`, `~/.aws`, Keychains, `.env*`, keys…), plus anything
   outside `~` and `$TMPDIR`. Applied at scan time and again as the last gate before any action,
   after resolving symlinks and `..`.
4. **Git-state-aware worktrees** (T13/T14) — Safe only if merged into the default branch, clean,
   no untracked files, no stash, upstream up to date, not the main worktree, not the current
   working dir of a running agent. The explanation names every reason it isn't Safe.
5. **In-use detection** (T20) — items held open or owned by a running tool process, or modified
   in the last hour, are downgraded to Keep.
6. **Dry run first.** The UI cannot execute without showing a `CleanupPlan` (paths, bytes,
   blockers, exact commands for `toolCommand` actions).
7. **Re-validation at execute time** — exists, not protected, not in use, not changed since scan
   (size/mtime), tier still not Keep. Failures skip the item, never abort silently.
8. **Trash by default.** `FileManager.trashItem`; permanent delete is off unless enabled in
   settings with a second confirmation. Worktrees: trash the dir, then `git worktree prune`.
   Models/Docker: the tool's own CLI so its index stays consistent.
9. **Audit log** — every action appended to `~/Library/Application Support/AIDiskKeeper/audit.jsonl`
   (time, path, bytes, method, trash location, rule id, result). Viewer in T24.
10. **No privilege escalation, no network, no telemetry.**
11. **Distribution** — Developer ID signed + notarized, hardened runtime, non-sandboxed in v1
    (needs `~` and Trash access across tools); Full Disk Access optional and explained.

## 8. Milestones

| Milestone | Outcome | Subtasks |
|---|---|---|
| **M1 — MVP** | Read-only scan of AI-tool data (Claude, Cursor, Codex, Gemini/Antigravity, Kiro, Windsurf, Copilot, Aider, Continue, Orca) with tiers + explanations; dry-run + Trash cleanup with audit log; runnable `.app` | T01–T12 |
| **M2 — Git-aware & breadth** | Worktree classification by git state; build artifacts per project/worktree; models (Ollama, HF, LM Studio); Docker; system junk; in-use detection; per-tool/per-project breakdown | T13–T20 |
| **M3 — Background & polish** | Menu bar summary; scheduled scans + notifications; user rules/ignore list; history viewer; performance cache; signed/notarized releases | T21–T26 |

## 9. Subtasks

Each subtask is one PR (≈1–2 days) and has a GitHub issue. "S" = the scaffold PR (#1).
Full scope and acceptance criteria live in each issue.

<!-- SUBTASKS:BEGIN -->
| ID | Issue | MS | Area | Title | Depends on | Wave |
|---|---|---|---|---|---|---|
| T01 | #2 | M1 | core | Core domain model: ScanItem, RiskTier, Category, ToolID | S (#1) | 1 |
| T02 | #3 | M1 | core | Directory sizing utility (allocated size, hardlinks, no symlink follow, cancellable) | S (#1) | 1 |
| T03 | #4 | M1 | rules | Scanner rule format (JSON schema), loader and validation | T01 (#2) | 2 |
| T04 | #5 | M1 | safety | Safety policy: protected-path denylist and path guard | T01 (#2) | 2 |
| T05 | #6 | M1 | core | Scan engine: concurrent, cancellable, progress stream | T01 (#2), T02 (#3), T03 (#4), T04 (#5) | 3 |
| T06 | #7 | M1 | rules | Rules: Claude Code and Claude desktop | T03 (#4) | 3 |
| T07 | #8 | M1 | rules | Rules: Cursor, Codex, Gemini/Antigravity, Kiro, Windsurf, Copilot, Aider, Continue, Orca | T03 (#4) | 3 |
| T08 | #9 | M1 | cleanup | Cleanup engine: dry-run plan, move to Trash, audit log | T01 (#2), T04 (#5) | 3 |
| T09 | #10 | M1 | ui | UI shell: scan screen, sidebar by tool/category, item list with tiers | T05 (#6) | 4 |
| T10 | #11 | M1 | ui | UI cleanup flow: selection, dry-run preview sheet, confirm, results | T08 (#9), T09 (#10) | 5 |
| T11 | #12 | M1 | ui | Onboarding: Full Disk Access guidance and scan scope settings | T09 (#10) | 5 |
| T12 | #13 | M1 | infra | App bundle packaging script and CI artifact | S (#1) | 1 |
| T13 | #14 | M2 | git | Git inspector: status, unpushed, merged, stash, worktree list | T01 (#2) | 2 |
| T14 | #15 | M2 | git | Worktree scanner: discover agent/stray worktrees and classify Safe/Review/Keep | T05 (#6), T13 (#14) | 4 |
| T15 | #16 | M2 | rules | Build artifact scanner: node_modules, .venv, target, .next, dist, DerivedData… | T05 (#6) | 4 |
| T16 | #17 | M2 | rules | Local model weights scanner: Ollama, LM Studio, Hugging Face (per model) | T05 (#6) | 4 |
| T17 | #18 | M2 | rules | Docker scanner and cleanup (images, volumes, build cache) | T05 (#6), T08 (#9) | 4 |
| T18 | #19 | M2 | rules | System junk rules: AI-tool logs, crash reports, caches, temp/scratchpad dirs | T03 (#4) | 3 |
| T19 | #20 | M2 | ui | Breakdown views: per-tool and per-project usage charts | T09 (#10), T14 (#15), T15 (#16) | 5 |
| T20 | #21 | M2 | safety | In-use detection: skip items belonging to running sessions | T05 (#6) | 4 |
| T21 | #22 | M3 | ui | Menu bar extra: reclaimable summary and quick actions | T09 (#10) | 5 |
| T22 | #23 | M3 | core | Scheduled scans and notifications | T21 (#22) | 6 |
| T23 | #24 | M3 | rules | User rules, ignore list and rule overrides | T03 (#4), T09 (#10) | 5 |
| T24 | #25 | M3 | ui | Cleanup history and audit log viewer | T08 (#9), T10 (#11) | 6 |
| T25 | #26 | M3 | core | Scan performance: incremental cache and large-tree benchmarks | T05 (#6), T15 (#16) | 5 |
| T26 | #27 | M3 | infra | Release pipeline: Developer ID signing, notarization, DMG | T12 (#13) | 2 |

**Waves** — tasks in the same wave have no dependency on each other and can run in parallel once the previous wave is merged:

- Wave 1: T01 (#2), T02 (#3), T12 (#13)
- Wave 2: T03 (#4), T04 (#5), T13 (#14), T26 (#27)
- Wave 3: T05 (#6), T06 (#7), T07 (#8), T08 (#9), T18 (#19)
- Wave 4: T09 (#10), T14 (#15), T15 (#16), T16 (#17), T17 (#18), T20 (#21)
- Wave 5: T10 (#11), T11 (#12), T19 (#20), T21 (#22), T23 (#24), T25 (#26)
- Wave 6: T22 (#23), T24 (#25)

### Acceptance criteria (summary)

**T01 — Core domain model: ScanItem, RiskTier, Category, ToolID** · M1 · area:core · depends on S (#1)

Add `Model/` to DiskKeeperCore: `RiskTier` (safe/review/keep, ordered), `ItemCategory` (aiToolData, worktree, buildArtifact, modelWeights, systemJunk, docker), `ToolID` (string-backed, open set), `ScanItem` (id, url, displayName, tool, category, project?, sizeAllocated, sizeLogical, fileCount, lastModified, tier, explanation, ruleID, cleanupMethod, flags), `ScanResult` aggregate with totals by tier / tool / project. All `Sendable` + `Codable`.

- [ ] Types compile under strict concurrency and are Codable round-trip tested
- [ ] `ScanResult` aggregation (by tier, tool, project) covered by unit tests
- [ ] No UI imports in DiskKeeperCore

**T02 — Directory sizing utility (allocated size, hardlinks, no symlink follow, cancellable)** · M1 · area:core · depends on S (#1)

`FileSizer` using `FileManager.enumerator` / `getattrlistbulk`-style resource keys (`totalFileAllocatedSizeKey`, `fileAllocatedSizeKey`, `isSymbolicLinkKey`, inode). Never follows symlinks, never crosses volume boundaries unless asked, dedupes hardlinks by inode, counts files, tracks newest mtime, checks `Task.isCancelled` periodically. Tolerates permission errors (records them, keeps going).

- [ ] Unit tests on a temp fixture tree: nested dirs, symlink loop, hardlink, unreadable dir
- [ ] Symlinked dirs are reported as 0 bytes and never traversed
- [ ] Cancellation stops enumeration within 100 ms on a large fixture
- [ ] Benchmark note in PR: time to size ~/.claude and node_modules-sized tree

**T03 — Scanner rule format (JSON schema), loader and validation** · M1 · area:rules · depends on T01 (#2)

Implement the data-driven rule format from docs/PLAN.md §5: `ScannerRule` Codable model, `RuleLoader` that loads bundled `Resources/Rules/*.json` (SwiftPM resources) plus optional user rules dir, path templating (`~`, `$TMPDIR`, `$APP_SUPPORT`, `$CACHES`), glob matching for `match`, tier conditions (`olderThanDays`, `newerThanDays`, `sizeOver`, `exists`). Validation rejects unknown keys, absolute paths outside allowed roots, and rules targeting protected paths.

- [ ] Schema documented in docs/rules.md with an example per match kind
- [ ] Loader tests: valid rule, unknown key, bad glob, protected-path target are rejected with clear errors
- [ ] Bundled rules load in tests via `Bundle.module`

**T04 — Safety policy: protected-path denylist and path guard** · M1 · area:safety · depends on T01 (#2)

Hard-coded, non-overridable `ProtectedPaths` policy consulted by both scanning (items under protected paths are never offered) and cleanup (final gate). Covers credentials/auth/config: `~/.claude.json`, `~/.claude/settings*.json`, `~/.claude/.credentials.json`, `~/.claude/{skills,agents,commands,plugins/config}`, `CLAUDE.md`, `~/.codex/{auth,config}.*`, `~/.gemini/{oauth_creds,settings,google_accounts}.json`, `~/.cursor/mcp.json`, `~/.config/github-copilot`, `~/.ssh`, `~/.aws`, `~/.gnupg`, Keychains, `.env*`, `*.pem`, `*.key`, `id_*`, home dir itself, `/`, `/System`, `/Applications`, plus any path not under the user's home or `$TMPDIR`. Path normalization resolves `..` and symlinks before checking.

- [ ] Table-driven tests: every listed pattern is blocked; symlink pointing into ~/.ssh is blocked; `..` traversal is blocked
- [ ] Guard is a pure function with no FS writes; 100% branch coverage
- [ ] PLAN safety section links to the code

**T05 — Scan engine: concurrent, cancellable, progress stream** · M1 · area:core · depends on T01 (#2), T02 (#3), T03 (#4), T04 (#5)

`ScanEngine` actor that expands rules into candidate paths, sizes them with bounded concurrency (TaskGroup, default = active CPU count), applies tier conditions and the protected-path filter, and emits `AsyncStream<ScanEvent>` (started, itemFound, progress, warning, finished, cancelled). Pluggable `Scanner` protocol so code-based scanners (git worktrees, Ollama, Docker) plug in next to JSON rules. Strictly read-only.

- [ ] Integration test runs engine over a fixture HOME and gets expected items/tiers
- [ ] Cancel mid-scan yields `cancelled` and no further events
- [ ] Test asserts no file in the fixture is modified (mtime/contents snapshot)
- [ ] `Scanner` protocol documented with one example implementation

**T06 — Rules: Claude Code and Claude desktop** · M1 · area:rules · depends on T03 (#4)

Bundled JSON rules for `~/.claude/projects/*` (per-project session transcripts, grouped by decoded project path), `todos`, `shell-snapshots`, `file-history`, `paste-cache`, `session-env`, `debug`, `transcripts`, `cache`, `backups`, `plugins/cache`, `~/.cache/claude`, `~/Library/Caches/claude-cli-nodejs`, and Claude desktop `~/Library/Application Support/Claude/{vm_bundles,claude-code-vm,claude-code,Cache,Code Cache}`. Sessions newer than 7 days = Keep, older than 30 = Safe, otherwise Review. Explanation strings say what is lost (e.g. `--resume` history).

- [ ] Fixture-based tests for each rule's tier logic
- [ ] Verified on a real machine: paths exist and sizes match `du -sh` within 5%
- [ ] No rule matches anything in the T04 denylist (test)

**T07 — Rules: Cursor, Codex, Gemini/Antigravity, Kiro, Windsurf, Copilot, Aider, Continue, Orca** · M1 · area:rules · depends on T03 (#4)

Bundled JSON rules for other AI tools: Cursor (`~/.cursor/extensions` caches, `~/Library/Application Support/Cursor/{Cache,CachedData,logs,User/workspaceStorage}`), Codex (`~/.codex/{sessions,log,archived_sessions}`), Gemini CLI / Antigravity (`~/.gemini/tmp`, `~/.gemini/antigravity` caches, `~/Library/Application Support/Antigravity` caches), Kiro (`~/.kiro`, `~/Library/Application Support/Kiro` caches), Windsurf/Codeium (`~/.codeium`, `~/Library/Application Support/Windsurf` caches), Copilot (VS Code `globalStorage/github.copilot*` caches only), Aider (`.aider.chat.history.md`, `.aider.tags.cache.v*` per repo), Continue (`~/.continue/{sessions,index,logs}`), Orca (`~/orca/workspaces/*` handed to the worktree scanner, `~/Library/Application Support/orca` caches/logs). Each rule marks the tool's config/auth files as protected.

- [ ] Each tool has at least one rule + fixture test; tools absent on the machine produce no items and no errors
- [ ] Paths double-checked against each tool's current docs; sources linked in rule `docs` field
- [ ] Electron app caches (Cache, Code Cache, GPUCache) are Safe; workspaceStorage/session history is Review

**T08 — Cleanup engine: dry-run plan, move to Trash, audit log** · M1 · area:cleanup · depends on T01 (#2), T04 (#5)

`CleanupEngine`: `plan(items) -> CleanupPlan` (dry run: per-item action, bytes, blockers) and `execute(plan)`. Before each action re-validates: item still exists, not a protected path (T04), size/mtime not changed beyond threshold since scan, tier is not Keep. Default action `FileManager.trashItem`; permanent delete exists in API but disabled unless a setting is on. Appends JSONL audit records (timestamp, path, bytes, action, trash URL, rule, result) to `~/Library/Application Support/AIDiskKeeper/audit.jsonl`. Partial failures do not abort the batch.

- [ ] Tests against a temp dir: dry run changes nothing; execute moves to Trash (or a test trash adapter) and writes audit lines
- [ ] Keep-tier and protected items are refused even if passed in
- [ ] Item modified after scan is skipped with reason `changedSinceScan`

**T09 — UI shell: scan screen, sidebar by tool/category, item list with tiers** · M1 · area:ui · depends on T05 (#6)

Main window with `NavigationSplitView`: sidebar (Overview, By tool, By category), content list (name, path, size, last used, tier badge), detail pane (explanation, rule, path reveal in Finder). Scan / Cancel button with progress. `@Observable` view model wrapping `ScanEngine` events. Sort by size, filter by tier.

- [ ] App launches via `swift run AIDiskKeeper`, scans the real home, and lists items with tiers
- [ ] Cancel works and UI stays responsive during a scan (no main-thread FS work)
- [ ] View model has unit tests with a fake engine

**T10 — UI cleanup flow: selection, dry-run preview sheet, confirm, results** · M1 · area:ui · depends on T08 (#9), T09 (#10)

Checkbox selection (Keep items not selectable; Review items require explicit per-item check, never "select all"), "Review cleanup" sheet showing the dry-run plan with totals and blockers, confirm button naming the bytes moved to Trash, result summary with per-item failures and "Open Trash" / "Show audit log" actions.

- [ ] Cannot reach execute without seeing the dry-run sheet
- [ ] "Select all Safe" exists; there is no bulk select for Review/Keep
- [ ] Manual QA checklist in PR (screenshots)

**T11 — Onboarding: Full Disk Access guidance and scan scope settings** · M1 · area:ui · depends on T09 (#10)

First-run screen explaining read-only scanning, what is scanned, and optional Full Disk Access (deep-link to System Settings > Privacy). Settings: scan roots for project discovery (default `~/`, `~/orca/workspaces`, `~/Developer`, `~/code`, `~/src`, `~/projects`), excluded paths, enabled tools. Persist via `UserDefaults`/JSON in Application Support.

- [ ] Scan works without FDA (gracefully reports inaccessible paths as warnings)
- [ ] Excluded paths are honored by the engine (test)
- [ ] Settings persist across launches

**T12 — App bundle packaging script and CI artifact** · M1 · area:infra · depends on S (#1)

`scripts/make-app.sh` turning the SwiftPM executable into `AI Disk Keeper.app` (Info.plist with bundle id, LSMinimumSystemVersion 14.0, LSUIElement=false, icon placeholder, resources), ad-hoc codesign. CI job uploads the zipped .app as an artifact on main. Keep `swift build`/`swift test` as the primary CI gate.

- [ ] `./scripts/make-app.sh` produces a launchable .app locally and on CI
- [ ] Bundle resources (rules JSON) load from inside the .app
- [ ] README documents the script

**T13 — Git inspector: status, unpushed, merged, stash, worktree list** · M2 · area:git · depends on T01 (#2)

`GitInspector` that shells out to `/usr/bin/git` (no libgit2) with timeouts and `GIT_OPTIONAL_LOCKS=0` so it never takes locks: `worktree list --porcelain`, `status --porcelain=v2 --branch` (dirty/untracked), `rev-list --count @{u}..HEAD` (unpushed; no upstream = unpushed), `branch --merged <default>` / `merge-base --is-ancestor`, `stash list`, default-branch detection (`origin/HEAD`, fallback main/master), last commit date. Returns a `GitState` value. Read-only: no fetch by default (optional fetch flag for later).

- [ ] Tests create fixture repos in a temp dir covering: clean+merged, dirty, untracked only, unpushed commits, no upstream, detached HEAD, stash present, missing/locked worktree
- [ ] Every git call has a timeout and is cancellable
- [ ] Verified `GIT_OPTIONAL_LOCKS=0` is set (test inspects env)

**T14 — Worktree scanner: discover agent/stray worktrees and classify Safe/Review/Keep** · M2 · area:git · depends on T05 (#6), T13 (#14)

Code-based `Scanner` that discovers worktrees from: repos under scan roots (`git worktree list`), `~/orca/workspaces/*/*`, `.claude/worktrees`, `.worktrees/`, Conductor/Cursor/Codex worktree dirs, and orphaned dirs whose `.git` file points at a missing gitdir. Classification: merged & clean & no stash & not current = Safe; dirty/untracked/unpushed/stash = Keep (explanation lists exactly why); stale (no commit >14d) but unmerged = Review; orphan (gitdir gone) = Review. Cleanup action for worktrees = trash dir then `git worktree prune` in the main repo (planned in T08's action enum).

- [ ] Fixture tests for each classification path
- [ ] Never offers the main working tree or the worktree the app/agent is currently running in
- [ ] Item explanation shows branch, ahead/behind, dirty file count, last commit

**T15 — Build artifact scanner: node_modules, .venv, target, .next, dist, DerivedData…** · M2 · area:rules · depends on T05 (#6)

Per-project discovery under scan roots (and inside each worktree from T14 when present): `node_modules` (sibling package.json), `.venv`/`venv` (pyvenv.cfg), `target` (Cargo.toml or pom.xml), `.next`, `.nuxt`, `.turbo`, `.parcel-cache`, `dist`/`build` (only with a build manifest sibling and gitignored), `__pycache__`, `.pytest_cache`, `.gradle`, `.dart_tool`, `Pods`, `~/Library/Developer/Xcode/DerivedData/*` (mapped back to project). Marker-file validation prevents matching user folders named `build`. Tier: Safe when the project is a Safe worktree or untouched >14 days; otherwise Review (regenerable but costs reinstall time). Prunes descent once an artifact dir is matched.

- [ ] Only gitignored or marker-validated dirs are reported (fixture tests incl. a hand-made `build/` folder that must NOT match)
- [ ] Items grouped by project and by worktree
- [ ] Scans a home with ~50 repos in under 30 s on Apple Silicon (documented)

**T16 — Local model weights scanner: Ollama, LM Studio, Hugging Face (per model)** · M2 · area:rules · depends on T05 (#6)

Code-based scanners: Ollama (`~/.ollama/models` manifests → blobs, shared-layer accounting so deleting one model reports only bytes unique to it; cleanup via `ollama rm` when the CLI is present, else refuse), Hugging Face (`~/.cache/huggingface/hub/models--*`, `datasets--*`, `xet` cache; per repo and revision, honoring `HF_HOME`/`HF_HUB_CACHE`), LM Studio (`~/.lmstudio/models`, `~/.cache/lm-studio/models`). Every model is Review tier, never part of "select all", shows last-used time where available.

- [ ] Fixture manifests test shared-blob accounting
- [ ] UI cannot bulk-select models (test on view model)
- [ ] Honors HF_HOME / OLLAMA_MODELS env overrides

**T17 — Docker scanner and cleanup (images, volumes, build cache)** · M2 · area:rules · depends on T05 (#6), T08 (#9)

If the `docker` CLI is reachable: read `docker system df -v --format json` and `docker image ls`/`volume ls` with labels; flag dangling images and build cache as Safe, unused images Review, volumes Keep unless unused and created by known agent sandboxes (by name/label heuristics) → Review. Report Docker Desktop disk image (`~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw`) size as info only. Cleanup uses `docker image rm` / `docker volume rm` / `docker builder prune` with dry-run output; never deletes Docker.raw.

- [ ] Graceful no-op when Docker is not installed or daemon is down
- [ ] Parsing tested with recorded JSON fixtures
- [ ] Cleanup commands shown verbatim in the dry-run sheet

**T18 — System junk rules: AI-tool logs, crash reports, caches, temp/scratchpad dirs** · M2 · area:rules · depends on T03 (#4)

Rules for: `~/Library/Logs/{Claude,Cursor,…}`, `~/Library/Logs/DiagnosticReports/*` filtered by AI-tool process names, `~/Library/Caches/{com.anthropic.*,com.todesktop.*,com.exafunction.*,…}`, `$TMPDIR/claude-*` and Claude Code scratchpads, `/private/tmp/claude-*` owned by user, package-manager caches commonly inflated by agents (`~/.npm/_cacache`, `~/Library/Caches/pnpm`, `~/.cache/uv`, `~/Library/Caches/pip`, `~/.bun/install/cache`) as Review with "regenerable" explanations. Temp dirs newer than 24 h = Keep (may belong to a running session).

- [ ] Crash-report filter tested on fixture .ips names
- [ ] Temp-dir rules never match dirs modified in the last 24 h
- [ ] Each rule's explanation states whether data is regenerable

**T19 — Breakdown views: per-tool and per-project usage charts** · M2 · area:ui · depends on T09 (#10), T14 (#15), T15 (#16)

Overview dashboard with Swift Charts: reclaimable bytes by tier, bar chart by tool, by project (merging worktrees + artifacts + sessions that map to the same repo), top 10 largest items. Clicking a bar filters the list. Project mapping utility (Claude `projects/` dir name decoding, worktree → main repo).

- [ ] Per-project totals equal the sum of their items (test)
- [ ] Charts readable in light/dark mode, VoiceOver labels on bars
- [ ] Clicking a tool/project filters the list

**T20 — In-use detection: skip items belonging to running sessions** · M2 · area:safety · depends on T05 (#6)

Before offering or cleaning, detect active use: running processes for each tool (`NSWorkspace.runningApplications`, `proc_listpids` for CLIs like `claude`, `codex`, `ollama`), open files via `proc_pidinfo`/`lsof -F` limited to candidate roots, and recent mtime (< 1 h). In-use items are downgraded to Keep with explanation "in use by <process>".

- [ ] Test with a helper process holding a file open in a fixture dir → item becomes Keep
- [ ] Detection adds < 2 s to a full scan (measured)
- [ ] Cleanup re-checks in-use state right before execution

**T21 — Menu bar extra: reclaimable summary and quick actions** · M3 · area:ui · depends on T09 (#10)

`MenuBarExtra` showing total AI-related usage and reclaimable Safe bytes, last scan time, per-tool top 5, actions: Scan now, Open app, Clean Safe items (opens the dry-run sheet in the main window — never one-click delete).

- [ ] Menu bar summary updates after a scan
- [ ] No cleanup path from the menu bar bypasses the dry-run sheet
- [ ] Setting to hide the menu bar item

**T22 — Scheduled scans and notifications** · M3 · area:core · depends on T21 (#22)

Optional scheduled scan (daily/weekly) while the app or its login item runs (`SMAppService.mainApp` login item + timer; `NSBackgroundActivityScheduler`). Low-priority QoS, skip on battery/low power. `UserNotifications` alert when reclaimable Safe bytes exceed a threshold or a tool grows by >X GB since last scan. Notifications deep-link to the review screen. Scheduled scans never delete.

- [ ] Scheduler unit-tested with an injectable clock
- [ ] Notification permission requested only when the user enables the feature
- [ ] Scheduled runs are read-only (test asserts no CleanupEngine call)

**T23 — User rules, ignore list and rule overrides** · M3 · area:rules · depends on T03 (#4), T09 (#10)

Users can add JSON rules in `~/Library/Application Support/AIDiskKeeper/Rules`, ignore specific items/paths ("never show"), and raise (never lower below Keep-guard) tiers. Settings UI to view rules, enable/disable per tool, open the rules folder, and validate with errors shown inline.

- [ ] Invalid user rule shows an error and does not break bundled rules
- [ ] User rules cannot target protected paths (reuse T03/T04 validation)
- [ ] Ignore list persists and is honored by the engine

**T24 — Cleanup history and audit log viewer** · M3 · area:ui · depends on T08 (#9), T10 (#11)

History screen reading `audit.jsonl`: date, items, bytes reclaimed, failures; "Reveal in Trash" when the trashed URL still exists; export as CSV. Lifetime reclaimed counter.

- [ ] Handles a corrupted/truncated audit line without crashing (test)
- [ ] Reveal-in-Trash disabled when the file is gone
- [ ] CSV export matches audit content

**T25 — Scan performance: incremental cache and large-tree benchmarks** · M3 · area:core · depends on T05 (#6), T15 (#16)

Persist last scan results with per-dir mtime fingerprints so rescans skip unchanged subtrees; add an XCTest `measure` benchmark over a generated 200k-file fixture; tune concurrency. Document numbers in docs/PERF.md.

- [ ] Second scan of an unchanged home is ≥3× faster than the first (benchmark)
- [ ] Cache invalidates correctly when a file is added deep in a tree (test)
- [ ] Benchmarks run in CI as a separate, non-blocking job

**T26 — Release pipeline: Developer ID signing, notarization, DMG** · M3 · area:infra · depends on T12 (#13)

Tag-triggered GitHub Actions workflow: build release, sign with Developer ID (secrets), notarize with `notarytool`, staple, package DMG, attach to a GitHub Release. Hardened runtime entitlements reviewed (no sandbox in v1 because Trash/FS access across ~; document the trade-off). Optional Sparkle feed later.

- [ ] Dry-run of the workflow on a test tag produces a notarized DMG (or documented secrets checklist if certs unavailable)
- [ ] Entitlements file committed and justified in docs
- [ ] Release notes template

<!-- SUBTASKS:END -->

## 10. Conventions

- Every PR: `swift build` + `swift test` green on CI; new logic has unit tests using fixture
  trees under a temp dir — **tests never touch the real home directory**.
- Scanners and rules ship with fixture tests; destructive code paths are tested only against
  temp dirs and a fake `TrashAdapter`.
- Explanations are user-facing copy: say what it is, what you lose, whether it regenerates.
