# Scanner rule format (schema v1)

AI Disk Keeper finds cleanable data with **rules**: small JSON files, one per tool. The app ships a set of
bundled rules and also reads rules you add yourself.

| Where | Path |
|---|---|
| Bundled | `Resources/Rules/*.json` inside the DiskKeeperCore resource bundle |
| User | `~/Library/Application Support/AIDiskKeeper/Rules/*.json` |

Files are loaded in file-name order, bundled first. Only `*.json` files are read (hidden files and non-regular
files are skipped; symlinks are followed for user rules only). At most 200 files per folder, 1 MiB each.
The rule *format* lives in this document; [`rules.schema.json`](rules.schema.json) is a JSON Schema
(draft 2020-12) for editor support only. **The Swift loader is the validator of record.**

Files are strict JSON (no comments, no trailing commas). **Every object rejects unknown keys.** A file is
accepted or rejected as a whole: one bad rule rejects the file, and the other files still load.

## File

| key | type | required | rules |
|---|---|---|---|
| `schemaVersion` | int | yes | must be `1` |
| `tool` | object | yes | `{ "id", "name", "docs"? }`. `id` is lowercase letters/digits separated by `-` (max 64). `name` is 1–60 chars. `docs`, if present, is an `https://` URL |
| `protect` | [string] | no | ≤ 64 *protect templates*, added to the global protected-path denylist (see Safety) |
| `rules` | [rule] | yes | 1…200 |

## Rule

| key | type | required | rules |
|---|---|---|---|
| `id` | string | yes | `<tool.id>.<name>`; the name is `[a-z0-9]+([.-][a-z0-9]+)*`; ≤ 96 chars; unique across **all** loaded files |
| `title` | string | yes | 1–80 chars |
| `category` | string | yes | `aiToolData`, `worktree`, `buildArtifact`, `modelWeights`, `systemJunk`, `docker` |
| `paths` | [string] | yes | 1…16 *path templates*, no glob characters |
| `match` | object | yes | see Match |
| `project` | object | no | `{ "from": … }`, one of `none` (default), `claudeProjectDirName`, `itemName`, `parentOfItem` |
| `tier` | string | yes | `safe`, `review` or `keep` |
| `tierWhen` | [object] | no | ≤ 8 entries; the first matching entry wins; none matching → `tier` |
| `explanation` | string | yes | 1–1000 chars. Shown to the user: what it is, what you lose, whether it regenerates |
| `cleanup` | object | no | default `{ "method": "trash" }` |

`category: modelWeights` can never be `safe`, neither in `tier` nor in any `tierWhen` entry ("model weights are
always Review").

### Path templates

A template is a symbolic root plus plain components: `ROOT` or `ROOT/component/...`.

| root | meaning |
|---|---|
| `~` or `$HOME` | home directory |
| `$TMPDIR` | the per-user temporary directory |
| `$APP_SUPPORT`, `$CACHES`, `$LOGS`, `$CONTAINERS`, `$GROUP_CONTAINERS` | `~/Library/Application Support`, `Caches`, `Logs`, `Containers`, `Group Containers` |
| `${NAME}` | environment variable (`NAME` = `[A-Z_][A-Z0-9_]{0,63}`). Must be absolute with no `..`, otherwise it counts as unset |
| `${NAME:-FALLBACK}` | same, with a fallback template (`~`, `$HOME`, … but not another `${…}`) |
| `/private/tmp`, `/tmp` | the only absolute roots allowed |

Components are non-empty, are not `.` or `..`, and contain none of `$ ~ \ NUL` (and no `* ? [ ]` in rule
paths). No trailing `/`, at most 1024 bytes. A template whose variable is unset and has no fallback is
*unavailable on this Mac*: that is not an error, the path is simply skipped.

Every rule path must lie inside the home directory, `$TMPDIR` or `/private/tmp`. For `kind: self` the path
must be strictly inside one of them; `children`/`find` may use the root itself as a container
(`$TMPDIR`, `/private/tmp`).

Protect templates use the same grammar but allow globs in components (`settings*.json`) and `**` as the
final component only (`~/.claude/skills/**`).

### Match

`kind` selects which other keys are allowed; any other key is rejected as unknown.

| kind | keys | semantics (executed by the scanner) |
|---|---|---|
| `self` | none | each existing expanded path is one item |
| `children` | `glob` (default `"*"`), `type` (default `any`), `depth` (1…3, default 1), `includeHidden` (default `false`), `exclude` ([glob], ≤ 16) | every entry exactly `depth` levels below the path whose final name matches `glob` (and no `exclude`) and whose type matches. Intermediate levels must be real directories (no symlinks). Without `includeHidden`, names starting with `.` are skipped at every level unless the glob itself starts with `.` |
| `find` | `name` (glob, required), `marker` (file name, required), `type` (default `directory`), `maxDepth` (1…10, required), `prune` (default `true`), `exclude` ([glob]) | recursive search for entries called `name` that have a sibling called `marker`. Stops descending at a match. Never descends into symlinks, other volumes, `.git`, `node_modules` or `exclude` names |

`type` is `directory`, `file` or `any`.

**Globs** match one path component: `*`, `?`, `[abc]`, `[a-z]`, `[!x]`, and `\` to escape. Matching is
case-insensitive and Unicode-normalization-insensitive. `/`, `**`, empty patterns, unclosed `[`, empty
classes, reversed ranges and a trailing `\` are rejected.

### Tiers

`tier` is the default risk tier. `tierWhen` entries are `{ "if": {…}, "tier": … }`, checked in order; the first
entry whose condition holds decides the tier. A condition is an object with at least one of these keys; all
the keys present must hold (AND):

| key | holds when |
|---|---|
| `olderThanDays` (number, 0 < n ≤ 3650) | the item was last modified strictly more than n days ago |
| `newerThanDays` (same range) | last modified strictly less than n days ago (a modification time in the future counts as brand new) |
| `sizeOverMB` (number > 0) | allocated size is strictly more than n × 1 000 000 bytes |
| `markerExists` (a file name) | an entry with that name exists next to / inside the item |

Items with an unknown modification time never satisfy the two age conditions. If both `olderThanDays` and
`newerThanDays` are given, `older < newer` is required (otherwise the condition could never hold).
`gitState` conditions are rejected: they are only available to the code scanners.

### Cleanup

| key | rules |
|---|---|
| `method` | `trash` (default), `none` (report only) or `toolCommand` |
| `command` | required with `toolCommand`: `^[a-z0-9][a-z0-9._-]*$`, no `/` |
| `arguments` | required with `toolCommand`: ≤ 16 strings; `{name}` and `{path}` placeholders are substituted at cleanup time |
| `requiresAppQuit` | optional bundle id (`com.example.App`) of an app that must be quit first |

`command`/`arguments` together with `trash` or `none` are rejected as unknown keys.

## Examples

Real bundle ids and paths are verified when the bundled rules are written; these examples only illustrate the
format.

### `children` with `depth: 2`, `tierWhen`, an env-var root, and `protect` (Claude Code)

The transcripts live at `projects/<project>/<session>.jsonl`; with `depth: 2` each file is its own item, and
the protected `memory/` folder next to them is never an item.

```json
{
  "schemaVersion": 1,
  "tool": { "id": "claude-code", "name": "Claude Code", "docs": "https://docs.claude.com/en/docs/claude-code" },
  "protect": ["~/.claude/settings*.json", "~/.claude/skills/**"],
  "rules": [
    {
      "id": "claude-code.transcripts",
      "title": "Session transcripts",
      "category": "aiToolData",
      "paths": ["${CLAUDE_CONFIG_DIR:-~/.claude}/projects"],
      "match": { "kind": "children", "depth": 2, "glob": "*.jsonl", "type": "file" },
      "project": { "from": "claudeProjectDirName" },
      "tier": "review",
      "tierWhen": [
        { "if": { "newerThanDays": 7 }, "tier": "keep" },
        { "if": { "olderThanDays": 30 }, "tier": "safe" }
      ],
      "explanation": "One conversation's history. Deleting it removes it from `claude --resume`; your code is not affected.",
      "cleanup": { "method": "trash" }
    },
    {
      "id": "claude-code.todos",
      "title": "Todo lists",
      "category": "aiToolData",
      "paths": ["~/.claude/todos"],
      "match": { "kind": "self" },
      "tier": "safe",
      "explanation": "Per-session todo lists written by Claude Code. Old sessions do not use them."
    }
  ]
}
```

### `self`, with an app that must be quit (Claude Desktop)

```json
{
  "schemaVersion": 1,
  "tool": { "id": "claude-desktop", "name": "Claude Desktop" },
  "rules": [{
    "id": "claude-desktop.cache", "title": "Web caches", "category": "aiToolData",
    "paths": ["$APP_SUPPORT/Claude/Cache", "$APP_SUPPORT/Claude/Code Cache", "$APP_SUPPORT/Claude/GPUCache"],
    "match": { "kind": "self" }, "tier": "safe",
    "explanation": "Chromium HTTP/code/GPU caches; rebuilt automatically.",
    "cleanup": { "method": "trash", "requiresAppQuit": "com.anthropic.claudefordesktop" }
  }]
}
```

### `children` plus extra `protect` entries (Cursor)

```json
{
  "schemaVersion": 1,
  "tool": { "id": "cursor", "name": "Cursor", "docs": "https://docs.cursor.com" },
  "protect": ["~/.cursor/mcp.json", "$APP_SUPPORT/Cursor/User/globalStorage/state.vscdb"],
  "rules": [
    { "id": "cursor.cache", "title": "Editor caches", "category": "aiToolData",
      "paths": ["$APP_SUPPORT/Cursor/Cache", "$APP_SUPPORT/Cursor/CachedData", "$APP_SUPPORT/Cursor/GPUCache"],
      "match": { "kind": "self" }, "tier": "safe",
      "explanation": "Electron caches; Cursor rebuilds them on launch.",
      "cleanup": { "method": "trash", "requiresAppQuit": "com.todesktop.230313mzl4w4u92" } },
    { "id": "cursor.workspace-storage", "title": "Workspace state", "category": "aiToolData",
      "paths": ["$APP_SUPPORT/Cursor/User/workspaceStorage"],
      "match": { "kind": "children", "type": "directory" },
      "tier": "review", "tierWhen": [{ "if": { "newerThanDays": 14 }, "tier": "keep" }],
      "explanation": "Per-workspace state (chat history, indexes) for one opened folder. Deleting it loses that workspace's chat history." }
  ]
}
```

### `self` with several candidate paths (Orca)

```json
{
  "schemaVersion": 1,
  "tool": { "id": "orca", "name": "Orca" },
  "rules": [
    { "id": "orca.logs", "title": "Orca logs", "category": "systemJunk",
      "paths": ["$APP_SUPPORT/orca/logs", "$LOGS/orca"],
      "match": { "kind": "self" }, "tier": "safe",
      "explanation": "Diagnostic logs; safe to delete, regenerated as Orca runs." }
  ]
}
```

### `children` in the temp directories (System)

```json
{
  "schemaVersion": 1,
  "tool": { "id": "system", "name": "System" },
  "rules": [
    { "id": "system.agent-scratch", "title": "Agent scratch dirs", "category": "systemJunk",
      "paths": ["/private/tmp", "$TMPDIR"],
      "match": { "kind": "children", "glob": "claude-*", "type": "directory" },
      "tier": "review", "tierWhen": [{ "if": { "newerThanDays": 1 }, "tier": "keep" }],
      "explanation": "Temporary dirs from agent sessions. Ones touched in the last 24 h may belong to a running session." }
  ]
}
```

### `find` (Aider)

```json
{ "schemaVersion": 1, "tool": { "id": "aider", "name": "Aider" },
  "rules": [{ "id": "aider.tags-cache", "title": "Repo map cache", "category": "aiToolData",
    "paths": ["~/Developer", "~/code", "~/src"],
    "match": { "kind": "find", "name": ".aider.tags.cache.v*", "marker": ".git", "maxDepth": 4 },
    "project": { "from": "parentOfItem" }, "tier": "safe",
    "explanation": "Aider's repo-map cache; rebuilt on next run." }] }
```

## Validation errors

A rejected file produces a `RuleLoadError` carrying the file, the JSON path and a message, rendered as
`<file>: <jsonPath>: <message>`, e.g. `my-rules.json: rules[2].match.glob: unclosed '[' at position 3 in glob '[abc'`.

| kind | meaning (example message) |
|---|---|
| `unreadableDirectory` | a rules folder exists but can't be listed |
| `unreadableFile` | the file can't be read |
| `fileTooLarge` | file is 2000000 bytes; the limit is 1048576 |
| `tooManyFiles` | more than 200 files in a folder; only the first 200 are loaded |
| `invalidJSON` | not valid JSON (comments and trailing commas included) |
| `unsupportedSchemaVersion` | unsupported schemaVersion 2 |
| `unknownKey` | unknown key 'foo' (at `rules[0].match`) |
| `missingKey` | missing required key 'explanation' (at `rules[0]`) |
| `typeMismatch` | a value has the wrong JSON type |
| `invalidValue` | a value is out of range or not allowed (bad enum value, `depth` 4, `gitState`, model weights as Safe, …) |
| `invalidGlob` | unclosed '[' at position 3 |
| `invalidPathTemplate` | must start with ~, $HOME, $TMPDIR, … |
| `invalidRuleID` | rule id 'other.r' must start with 'mytool.' |
| `duplicateRuleID` | rule id 'x.y' is already defined (bundled rules win over user rules) |
| `pathOutsideAllowedRoots` | /etc/x is outside the home directory, the temporary directory and /private/tmp |
| `protectedPathTarget` | `<path>`: the protected-path guard refuses it |
| `invalidProtectPattern` | a protect pattern such as `~` that would protect everything |
| `guardUnavailable` | the protected-path guard couldn't be built; **no rules are loaded** (fails closed) |

## Safety

- Rules can only add protection: `protect` patterns are added to the built-in denylist, never removed from it.
- Rules can't target anything outside the home directory, `$TMPDIR` and `/private/tmp`.
- A rule path that the protected-path guard refuses rejects the whole file. For `children`/`find` rules a
  container that is only an *ancestor* of protected data (for example `~/.claude/projects`) is allowed, and each
  resulting item is checked again by the scanner.
- Rule files never execute anything by themselves; `toolCommand` names a CLI that is resolved and run by the
  cleanup engine, with the app's own checks.
