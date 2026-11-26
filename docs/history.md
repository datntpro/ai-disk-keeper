# Cleanup History (T24)

A read-only view of `~/Library/Application Support/AIDiskKeeper/audit.jsonl`.

- **Never writes** the log: no rotation, repair or deletion. Corrupted lines are counted and shown as a banner
  ("N entries couldn't be read"); lines from a newer `schemaVersion` are counted as unknown, not dropped silently.
- Logs over 50 MB: only the last 50 MB are read (first partial line dropped) and a notice is shown.
- Runs are grouped by `runID` (app-quit flows by `flowID`). Reclaimed bytes = `trashed` + `deleted` entries only.
  The lifetime counter is the sum over every readable run.
- **Reveal in Trash** is enabled only when `trashPath` exists now (`lstat`, symlinks not followed) and lies inside
  `~/.Trash` or `/.Trashes/<uid>`. There is no restore and no delete-from-Trash.
- **Export CSV** (RFC 4180, CRLF, UTC ISO-8601): `timestamp,runID,result,action,bytes,path,trashPath,ruleID,tool,reasons,error,bundleID,command,exitStatus`.
  One row per readable record in file order; `reasons` joined with `;`, `command` (argv) joined with spaces;
  app-quit lines export with `action = quit:<mode>`. Cells are not sanitized against spreadsheet formulas, to keep the export faithful.
