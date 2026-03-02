---
status: complete
priority: p2
issue_id: "016"
tags: [session-end, sync-on-end, error-handling, logging]
dependencies: []
---

# sync-on-end silently swallows all failures — errors undetectable

## Problem Statement

`permissionsync-sync-on-end.sh` runs `sync-permissions.sh --apply >/dev/null 2>&1 || true`. The `|| true` plus full stderr suppression means any sync failure (corrupted JSONL, permission error writing `settings.json`, `jq` not on PATH) is permanently discarded. The user has no way to know the session-end sync failed.

## Findings

**File:** `permissionsync-sync-on-end.sh` line 11

```bash
"$SYNC" --apply >/dev/null 2>&1 || true
```

Failure modes that are currently silent:
- `jq` not on PATH in the hook's environment
- `settings.json` is read-only
- `permission-approvals.jsonl` (or `confirmed-approvals.jsonl` after todo 006) is corrupted
- `sync-permissions.sh` itself has a bug

The `SessionEnd` hook runs after the user's session ends. Claude Code does capture the hook's exit code and output, but the current design always exits 0 and discards all output — so nothing surfaces even in Claude Code's hook error reporting.

**Design question:** Is silent-success intentional for a background sync, or should errors be recoverable?

## Proposed Solutions

### Option A — Log stderr to a file (recommended)

```bash
SYNC_LOG="$(dirname "$SYNC")/../sync-on-end-errors.log"
"$SYNC" --apply >>"$SYNC_LOG" 2>&1 || true
```

**Pros:** Failures are preserved and discoverable. Consistent with the project's logging-first approach.
**Cons:** Creates another log file to manage. Log path needs to follow `CLAUDE_PERMISSION_LOG` convention.
**Effort:** small
**Risk:** low

### Option B — Preserve stderr, suppress stdout only

```bash
"$SYNC" --apply 2>/dev/null || true
```

**Pros:** Sync output (rule counts, progress) goes to the session terminal. Errors still discarded.
**Cons:** Partial fix — errors still lost.
**Effort:** trivial
**Risk:** low

### Option C — Use permissionsync-log-hook-errors pattern

Log the failure to `hook-errors.jsonl` on failure:
```bash
if ! "$SYNC" --apply >/dev/null 2>&1; then
    echo '{"timestamp":"...","error":"sync_failed"}' >> "$ERRORS_LOG"
fi
```

**Pros:** Failures appear in the unified error log already monitored by PostToolUseFailure infrastructure.
**Cons:** More implementation.
**Effort:** medium
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] A sync failure produces a recoverable artifact (log file or error log entry)
- [ ] The artifact path follows `CLAUDE_PERMISSION_LOG` directory convention
- [ ] Test: mock sync that exits 1 → error is captured (not silently swallowed)

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Code simplicity review finding

**By:** Claude Code (code-simplicity-reviewer agent)

**Actions:**
- Identified blanket `>/dev/null 2>&1 || true` in sync-on-end.sh
- Enumerated failure modes that are currently undetectable
- Surveyed options for error preservation

**Learnings:**
- "Background" hooks should still log errors to a recoverable location
- Silent-success is never the right default for operations that modify state (settings.json)
