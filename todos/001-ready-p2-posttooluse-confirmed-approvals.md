---
status: ready
priority: p2
issue_id: "001"
tags: [hook, logging, correctness]
dependencies: []
---

# PostToolUse confirmed-approvals log

## Problem Statement

The current `PermissionRequest` hook fires at *request* time, so the JSONL log captures
every request — including ones the user **denies**. There's no way to distinguish approved
from denied operations in the log. This makes confidence scoring, analytics, and
"auto-approve previously confirmed" harder than it should be.

## Findings

Claude Code supports a `PostToolUse` hook that fires only when a tool **successfully
executes** (i.e., was approved and ran). This gives a clean "confirmed approved" signal
distinct from the PermissionRequest log.

PostToolUse payload schema (based on Claude Code docs):
```json
{
  "tool_name": "Bash",
  "tool_input": {"command": "git status"},
  "tool_response": {"output": "..."},
  "cwd": "/path/to/repo",
  "session_id": "..."
}
```

## Proposed Solutions

### Option A — Separate confirmed-approvals.jsonl (Recommended)
- New script `log-confirmed.sh` sourcing permissionsync-lib.sh
- Appends to `~/.claude/confirmed-approvals.jsonl` (separate from requests log)
- install.sh/setup-hooks.sh wire `PostToolUse` hook
- sync-permissions.sh gains `--from-confirmed` flag

**Pros:** Clean separation, clear semantics, doesn't change PermissionRequest behavior
**Cons:** Two log files to manage
**Effort:** medium
**Risk:** low

### Option B — Annotate existing JSONL
- Add `"confirmed": true` field to existing entries by matching session+rule
**Pros:** Single log file
**Cons:** Requires correlating two events, complex, racy
**Effort:** large
**Risk:** medium

## Recommended Action

Implement Option A:
1. Create `log-confirmed.sh` — PostToolUse hook, appends to `~/.claude/confirmed-approvals.jsonl`
   - Reuses `build_rule_v2()` from permissionsync-lib.sh
   - Same JSON structure as PermissionRequest log plus `tool_response` summary
2. Update `install.sh` and `setup-hooks.sh` to wire `PostToolUse` hook
3. Update `sync-permissions.sh`: add `--from-confirmed` flag
4. Update `flake.nix` to include new script
5. Write tests for the new hook

Note: Use `git rev-parse --git-common-dir` in confirmed log for consistent worktree path.

## Acceptance Criteria

- [ ] `log-confirmed.sh` exists, sources permissionsync-lib.sh
- [ ] Appends to `~/.claude/confirmed-approvals.jsonl` on each successful tool use
- [ ] install.sh wires `PostToolUse` hook in settings.json
- [ ] setup-hooks.sh wires `PostToolUse` hook idempotently
- [ ] `sync-permissions.sh --from-confirmed` uses confirmed log as source
- [ ] flake.nix updated with new script
- [ ] Unit tests pass

## Work Log

### 2026-02-27 — Todo created

**By:** Claude Code

**Actions:**
- Extracted from implementation plan; ready to implement in next batch

**Learnings:**
- PostToolUse hook gives clean "confirmed approved" signal
- Keep confirmed log separate from request log for clarity
