---
status: pending
priority: p3
issue_id: "005"
tags: [automation, hooks]
dependencies: []
---

# Auto-sync rules at session boundary

## Problem Statement

New rules accumulate in JSONL across a session but don't appear in settings.json until
the user manually runs `sync --apply`. This means repeat prompts across sessions for
the same operations.

## Findings

Claude Code may support a `SessionEnd` (or equivalent lifecycle) hook that fires when
a session ends. If so, firing `sync-permissions --apply` automatically would eliminate
the manual sync step.

**Open question**: Does Claude Code actually support a SessionEnd or SessionStop hook?
The hook events documented so far are:
- `PermissionRequest` ✅ (used)
- `PostToolUse` ✅ (planned in todo 001)
- `PreToolUse` ✅ (known to exist)
- `Notification` ✅ (known to exist)
- `SessionStart` / `SessionEnd` — **unverified**

This todo is PENDING triage until the hook availability is confirmed.

## Proposed Solutions

### Option A — SessionEnd hook (if available)
Wire `sync-permissions.sh --apply` as a `SessionEnd` hook.

### Option B — PostToolUse with threshold
After N new log entries appear (e.g. 5), trigger a sync automatically.
More complex, fires mid-session.

### Option C — Periodic background sync
Not feasible in Claude Code's hook model.

## Recommended Action

*(Pending verification of Claude Code hook event availability)*

1. Check Claude Code docs / source for SessionEnd hook support
2. If available: wire `sync-permissions.sh --apply` as SessionEnd hook in install.sh
3. If unavailable: implement Option B or document as manual step

## Acceptance Criteria

- [ ] Claude Code SessionEnd hook availability confirmed or denied
- [ ] If available: auto-sync wired in install.sh and setup-hooks.sh
- [ ] No data loss: sync only promotes rules already in JSONL
- [ ] Tests verify sync runs at correct trigger

## Work Log

### 2026-02-27 — Todo created

**By:** Claude Code

**Actions:**
- Created as pending; requires investigation of Claude Code hook events

**Learnings:**
- Do not implement until hook availability is confirmed
- Option B (PostToolUse threshold) is fallback
