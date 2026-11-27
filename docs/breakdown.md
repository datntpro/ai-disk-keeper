# Breakdown views (T19)

The AI Tools module shows two collapsible charts above its list: **By tool** and **By project**. The Worktrees module
shows **By project**. Bars are stacked by tier (Safe / Review / Keep), show the top 8 plus "Other", and carry an
accessibility label `Name, total, safe`.

- Clicking a bar only **filters** the list (`ItemQuery.toolFilter` / `projectID`, ANDed with scope, tier and search). It
  never selects items for cleanup. "Clear filter" (or clicking the bar again) restores the list. Leaving the module clears it.
- Charts are not on Overview and do not change module badge numbers.

## What counts as a project

`ProjectKeyResolver` (DiskKeeperCore) maps an item's `ProjectRef` to a repo root:

1. Walk up from the project path to the nearest directory containing `.git`.
2. If `.git` is a directory, that directory is the project.
3. If `.git` is a file (`gitdir: <main>/.git/worktrees/<name>`), read it (≤ 4 KiB), follow `commondir` (or the path shape)
   to `<main>`: linked worktrees merge into their main repository.
4. No repo, a malformed `.git` file, or a `name:` id: the project is unchanged (`name:` ids fall back to the decoded name).
   Items without any project land in "No project".

It only reads paths the scan already produced: no `git` process and no directory listing, so no permission prompts.
Results are cached for a minute.
