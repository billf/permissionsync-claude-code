---
status: complete
priority: p1
issue_id: "008"
tags: [watch-config, guard, hooks, config-change]
dependencies: []
---

# ConfigChange guard only checks 2 of 5 hooks — new hooks unmonitored

## Problem Statement

`permissionsync-watch-config.sh` is supposed to detect when permissionsync hooks have been removed from `settings.json`. It only checks `PermissionRequest` and `PostToolUse`. The 3 hooks introduced in the same commit (`PostToolUseFailure`, `ConfigChange`, `SessionEnd`) are never verified. This includes the watch-config script itself — it won't detect its own removal.

## Findings

**File:** `permissionsync-watch-config.sh` lines 20–26

```bash
has_permreq=$(jq -r '[.hooks.PermissionRequest[]?.hooks[]?.command // ""] | map(select(test("/.claude/hooks/"))) | length' "$SETTINGS_PATH" 2>/dev/null || echo 0)
has_postuse=$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command // ""] | map(select(test("/.claude/hooks/"))) | length' "$SETTINGS_PATH" 2>/dev/null || echo 0)

HOOKS_INTACT=true
if [[ $has_permreq -eq 0 ]] || [[ $has_postuse -eq 0 ]]; then
    HOOKS_INTACT=false
fi
```

The three hooks that are NOT verified:
- `PostToolUseFailure` → `permissionsync-log-hook-errors.sh`
- `ConfigChange` → `permissionsync-watch-config.sh` (the script itself!)
- `SessionEnd` → `permissionsync-sync-on-end.sh`

**Self-referential problem:** If someone removes the `ConfigChange` hook from `settings.json`, the watch-config script won't fire at all — and even if it did fire from a backup path, it wouldn't detect its own absence.

**Test gap:** `tests/test-permissionsync-watch-config.sh` fixture (`GOOD_SETTINGS`) only includes the original 2 hooks. There are no test cases asserting `HOOKS_INTACT=false` when any of the 3 new hooks are missing.

## Proposed Solutions

### Option A — Extend guard to check all 5 hooks (recommended)

Add three more jq probes after the existing two:
```bash
has_posttooluse_fail=$(jq -r '[.hooks.PostToolUseFailure[]?.hooks[]?.command // ""] | map(select(test("/.claude/hooks/"))) | length' "$SETTINGS_PATH" 2>/dev/null || echo 0)
has_configchange=$(jq -r '[.hooks.ConfigChange[]?.hooks[]?.command // ""] | map(select(test("/.claude/hooks/"))) | length' "$SETTINGS_PATH" 2>/dev/null || echo 0)
has_sessionend=$(jq -r '[.hooks.SessionEnd[]?.hooks[]?.command // ""] | map(select(test("/.claude/hooks/"))) | length' "$SETTINGS_PATH" 2>/dev/null || echo 0)

HOOKS_INTACT=true
if [[ $has_permreq -eq 0 ]] || [[ $has_postuse -eq 0 ]] || \
   [[ $has_posttooluse_fail -eq 0 ]] || [[ $has_configchange -eq 0 ]] || \
   [[ $has_sessionend -eq 0 ]]; then
    HOOKS_INTACT=false
fi
```

**Pros:** Complete coverage; self-referential monitoring.
**Cons:** 5 separate jq invocations — could be combined into one.
**Effort:** small
**Risk:** low

### Option B — Single jq call checking all 5 keys

Combine into one jq expression that checks all 5 events at once:
```bash
missing_hooks=$(jq -r '
  ["PermissionRequest","PostToolUse","PostToolUseFailure","ConfigChange","SessionEnd"]
  | map(. as $ev | . + " " + (
      [(.hooks[$ev] // [])[]?.hooks[]?.command // ""]
      | map(select(test("/.claude/hooks/"))) | length | tostring
    ))
  | .[]' "$SETTINGS_PATH" 2>/dev/null)
```

**Pros:** One jq invocation, more efficient.
**Cons:** More complex jq expression, harder to maintain.
**Effort:** medium
**Risk:** medium

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] Guard checks all 5 hooks: PermissionRequest, PostToolUse, PostToolUseFailure, ConfigChange, SessionEnd
- [ ] `HOOKS_INTACT=false` when any of the 3 new hooks are absent
- [ ] Test fixture updated to include all 5 hooks in `GOOD_SETTINGS`
- [ ] New test cases: each of the 3 new hooks absent → `HOOKS_INTACT=false` + warning emitted
- [ ] Existing tests still pass

## Work Log

### 2026-03-01 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Pattern review + architecture review finding

**By:** Claude Code (pattern-recognition-specialist + architecture-strategist agents)

**Actions:**
- Identified guard only checks 2 of 5 installed hooks
- Noted self-referential gap: ConfigChange hook cannot detect its own removal
- Confirmed test fixture only populates original 2 hooks

**Learnings:**
- A watchdog script must monitor all hooks it's responsible for, including itself
- Test fixtures must be updated in lockstep with the guard logic being tested
