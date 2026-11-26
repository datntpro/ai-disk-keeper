# Cleanup History

The History screen is a **read-only** view of `audit.jsonl` (`$APP_SUPPORT/AIDiskKeeper/audit.jsonl`). It never writes, rotates or repairs the log.

- **Parsing** (`AuditHistoryReader`): one JSON object per line. Cleanup lines group by `runID`, Uninstaller quit lines (`kind: "appQuit"`) by `flowID`. Malformed lines (including a truncated last line) are counted and shown as a banner; lines with `schemaVersion > 1` are counted as unknown, never dropped silently. Files over 50 MB: only the tail is read (the partial first line is dropped) and a notice is shown.
- **Lifetime counter**: sum of `trashed` + `deleted` bytes over everything read. Quit lines and skipped/failed lines don't count.
- **Reveal in Trash**: enabled only if `trashPath` is inside `~/.Trash` or `<volume>/.Trashes/<uid>` (no `..`) and still exists (`lstat`, symlinks not followed). No "Put back".
- **Export CSV**: RFC 4180, CRLF, one row per understood line in file order. Columns: `timestamp,runID,result,action,bytes,path,trashPath,ruleID,tool,reasons,error,bundleID,command,exitStatus`. `reasons` are joined with `;`, `command` argv with a space, timestamps are ISO-8601 UTC. Quit rows use `action = quit.<mode>`, `bytes = 0`.
- Loading runs off the main actor; the screen reloads on appear and when the cleanup sheet closes.
