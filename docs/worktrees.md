# Worktree inventory (H3, read-only)

Worktrees screen, **Inventory** tab. It lists every linked git worktree it can find, with a verdict on whether it is
provably finished. **Nothing is removed, pruned, locked or fetched** by this feature. Cleaning is a later PR (H4) and
always keeps the branch.

## Discovery

Deduped by realpath. Main checkouts and bare repositories are context only and are never candidates.

1. **Orca**: `orca worktree list --json`, resolved from absolute paths only (`/Applications/Orca.app/...`,
   `~/Applications/Orca.app/...`), never `PATH`. 10 s timeout, minimal environment, no pairing flags. If Orca is absent or
   fails, the source is skipped with a warning and git is used alone. Orca's `linkedPR` and `workspaceStatus` are shown as
   hints and are never trusted for "merged".
2. **Git**: `git worktree list --porcelain` for every known main repository (from Orca, from `.git` folders under the
   project folders to depth 3 — skipping `node_modules`, `.build`, `DerivedData`, hidden folders, and `Library` /
   `Documents` / `Desktop` / … when a root is the home folder — and from `~/orca/workspaces/*/*`).
3. **Extra roots**: `<repo>/.claude/worktrees/*`, `<repo>/.worktrees/*`, `~/conductor/workspaces/*/*`,
   `~/.codex/worktrees/*/*`.
4. **Orphans**: a folder whose `.git` file points at a missing git directory. Always *Review*, never *Safe to clean*.

Symlinks are never followed. Only `.git` files and git's own output are read.

## The seven checks

`WorktreeClassifier.verdict` is pure. Every check is `true`, `false` or **unknown**; unknown fails closed. A worktree is
**Safe to clean** only if all seven pass.

| Check | Passes when |
|---|---|
| Not a main checkout | not main, not bare, not an orphan, not this app's own folder, `ProtectedPaths` allows it |
| Work is finished | see below |
| No uncommitted changes | no modified / staged / untracked / conflicted files, no merge/rebase/…, no index lock, not `git worktree lock`ed, submodules clean, nothing hidden from `status` |
| No ignored secrets or data | no ignored `.env*`, keys, `*.sqlite` … (the GitPorcelain "precious" set) |
| Commits are kept | on a branch (the branch is kept); a detached HEAD needs `rev-list HEAD --not --branches --remotes` = 0 |
| Nothing running here | no process has its cwd inside (libproc, no `lsof`); the process table must be readable |
| Idle long enough | newest activity is at least `worktreeIdleHours` (default 3, range 1–72) old |

**Activity** = max(Orca `lastActivityAt`, mtime of `<gitdir>/index`, `logs/HEAD`, `HEAD`, newest file change seen while sizing).
The source is named in the inspector.

**Work is finished** (the first method that proves it is named in the inspector):

1. PR merged **and** HEAD equals, or is an ancestor of, the PR's `headRefOid` (only with the `gh` opt-in).
2. PR closed (not merged) **and** every commit is on a remote (only with the `gh` opt-in).
3. HEAD is an ancestor of the remote-tracking default branch (`origin/<default>`).
4. `git cherry <base> HEAD`: every line starts with `-`, **and** every commit is on a remote.
5. Every path the branch changed (merge-base..HEAD) is byte-identical in `<base>` (squash-merges), **and** every commit is on a remote.

Methods 4 and 5 need `commitsNotOnAnyRemote == 0`: a branch whose commits exist on no remote is never Safe, even when
its content is already in the default branch (it shows as Review, "N commits are on no remote"). A default branch that
is only local (`refs/heads/main`, no `origin`) proves nothing. All proofs use local refs; `git fetch` is never run, so
they are only as fresh as your last fetch.

Method 5 is two `git diff --raw` calls, not `git merge-tree --write-tree`: that command writes tree objects (and git
touches the mtime of existing objects), and an inventory must leave `.git` exactly as it found it. A test snapshots
every path, size and mtime under `.git` before and after an inventory. Method 5 is stricter than a real merge: a changed
path that differs from `<base>` in any way is "no", which only turns Safe into Review.

## Tiers

- **Safe**: all checks pass.
- **Keep**: a known blocker (changes, ignored secrets, unpushed detached commits, a running process, recent activity, main checkout, own folder).
- **Review**: clean but not proven finished, an orphan, or something could not be checked.

## GitHub (opt-in)

Settings → Scan scope → Worktrees, or the toggle in the Worktrees toolbar: **Check PR status with GitHub CLI**. Off by
default. Turning it on the first time shows a consent sheet. It then runs, per repository, only:

`gh pr list --repo <owner/name from origin> --state all --limit 300 --json number,state,headRefName,headRefOid,mergedAt,closedAt,url`

with `GH_PROMPT_DISABLED=1` and `NO_COLOR=1`, a 15 s timeout and a 10 minute in-memory cache. `gh` comes from
`/opt/homebrew/bin/gh` or `/usr/local/bin/gh`. Only github.com remotes are used. Nothing else leaves the Mac. PRs are
matched by head branch name.

## Not in H3

Removing worktrees (H4), real reclaimable bytes (H6), the open-file index (T20; the field exists and is ignored until then).
