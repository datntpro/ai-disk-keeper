# Protected paths (T04)

`ProtectedPaths.check(path)` is the single gate used by scan (T05) and cleanup (T08). The built-in
table is hard-coded and cannot be overridden; rules may only **add** anchored patterns.

## Semantics

- A path is denied if **either its lexical form or its resolved (symlink-free) form** is denied. This
  covers symlinks into `~/.ssh`, intermediate symlinks that escape home, and `link/..` tricks.
- Any raw `..` component is rejected (`parentTraversal`). Scanners never produce one.
- The pure core `evaluate(raw:resolution:)` does no syscalls. `SystemPathResolver` uses only
  `realpath`/`lstat` (read-only). Nothing is cached: re-check right before acting.
- Comparison runs on a canonical key: `/tmp`, `/var`, `/etc` → `/private/...`;
  `/System/Volumes/Data/X` → `/X`; case-folded; Unicode NFD; split into components.
- Allowed roots: home, `$TMPDIR`, `/private/tmp`. Everything else is `outsideAllowedRoots` or
  `systemLocation`. Roots are injected; this module never reads the real home.
- Reasons are either **hard** or **container**. `protectedLocation` and `containsProtectedPath` mean the
  path itself must never be an item, but it may be scanned *inside*. A hard reason always wins.

- **Root validation (fail closed):** `init` throws `invalidRoot` if a home or `$TMPDIR` form (lexical or
  resolved) has fewer than 2 components, is `/Volumes/<vol>`, equals or contains a system root, or (home
  outside `/Volumes`; always for `$TMPDIR`) lies under one.
- **Glob escaping:** `~`/`$APP_SUPPORT` expansion escapes `\ * ? [ ]` in the home path. Entries in
  `additionalPatterns` are globs: callers embedding literal paths (e.g. `$HOME`, `$TMPDIR`) must wrap
  them in the public helper `ProtectedPaths.escapeGlob(_:)`.

## Pattern classes

1. **Anchored**: absolute. Denies the path, everything below it, and its *ancestors*
   (`~/.claude` is `containsProtectedPath` because of `~/.claude/.credentials.json`).
2. **Exact-only**: only the directory itself (e.g. `~/Documents`); children stay allowed.
3. **Basename**: any component below the allowed root (`.env`, `*.pem`, `.git`, ...).
4. **System roots**: `/System`, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/opt`, `/cores`,
   `/private/etc`, `/private/var/db`, `/private/var/root`, `/Volumes`, `/Network`, `/dev`.

## Table

The authoritative table is `ProtectedPaths.builtInAnchored`, `builtInExactOnly`, `builtInBasenames` and
`systemRoots` in `Sources/DiskKeeperCore/Safety/ProtectedPaths.swift`; it is covered by table-driven
tests. Summary:

| Group | Entries |
|---|---|
| Claude | `~/.claude.json*`, `~/.claude/{settings*.json,.credentials.json,CLAUDE.md,skills,agents,commands,hooks,output-styles,keybindings.json}`, `~/.claude/plugins/{config*,*.json}`, `~/.claude/projects/*/memory` |
| Codex | `~/.codex/{auth.json,config.*,AGENTS.md}` |
| Gemini | `~/.gemini/{oauth_creds.json,settings.json,google_accounts.json,GEMINI.md}` |
| Cursor | `~/.cursor/mcp.json`, `$APP_SUPPORT/Cursor/User/{settings.json,keybindings.json,snippets}` |
| Copilot | `~/.config/github-copilot` |
| Dev credentials | `~/.ssh ~/.aws ~/.gnupg ~/.azure ~/.kube ~/.docker/config.json ~/.config/{gh,gcloud,git} ~/.gitconfig ~/.git-credentials ~/.netrc ~/.npmrc ~/.pypirc ~/.password-store` |
| macOS | `~/Library/{Keychains,Preferences,Mobile Documents,CloudStorage,Mail,Messages}`, `~/.Trash` |
| Docker | `~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw` |
| Other credentials | `$APP_SUPPORT/Claude/claude_desktop_config.json`, `~/.cargo/credentials*`, `~/.config/op`, `~/.vault-token`, `~/.terraform.d/credentials*`, `~/.gem/credentials`, `~/.m2/settings*.xml`, browser `Login Data*`/`Cookies*`/Firefox `logins.json`/`key4.db`/`cookies.sqlite`, `~/Library/Cookies`, `/private/tmp/com.apple.launchd.*` |
| Self | `$APP_SUPPORT/AIDiskKeeper` |
| Exact-only | `~`, `~/Library` and its main subfolders, `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`, `~/Public`, `~/Applications`, `~/Developer`, `~/.cache`, `~/.config`, `~/.local`, `~/.local/share`, `~/orca`, `~/orca/workspaces`, `/private/tmp`, `$TMPDIR` (as an allowed root) |
| Basenames | `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.keychain`, `*.keychain-db`, `id_rsa*`, `id_ed25519*`, `id_ecdsa*`, `id_dsa*`, `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.credentials.json`, `.git` |

## Known limits

- Hardlinks cannot be detected; trashing a hardlink leaves the original intact.
- APFS clones are indistinguishable from ordinary files.
- On a case-sensitive volume, case folding only over-blocks (the safe direction).
- Basenames are narrowed on purpose: `id_*` would match `id_utils/` and `.env*` would match `.envrc`;
  the concrete key and `.env`/`.env.*` names cover the intent.
- Basename rules look only at the candidate's own components, not inside it: a worktree that *contains*
  `.env` or `*.pem` is not denied (T14 must downgrade such worktrees).
- `~/.claude/projects/<proj>` can never be an item (it contains `memory`); T06 must emit per-transcript
  (`*.jsonl`) items.
