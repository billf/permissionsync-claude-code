---
status: ready
priority: p1
issue_id: "007"
tags: [install, backup, data-loss, settings]
dependencies: []
---

# settings.json original backup lost: each install step overwrites .bak

## Problem Statement

Both `install.sh` and `setup-hooks.sh` take a backup of `settings.json` as `.bak` on each modifying step. On a fresh install where all 5 hooks need to be wired, each step overwrites the previous `.bak`. After a full run, `settings.json.bak` contains only the state before the *last* modifying step — not the original pre-install state. The user's original `settings.json` is permanently unrecoverable.

## Findings

**Files:** `install.sh` lines 154, 185, 215, 245, 275 — `setup-hooks.sh` same pattern

Each of the 5 hook-wiring steps does:
```bash
cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
mv "$TEMP_N" "$SETTINGS"
```

On a fresh install, all 5 steps modify `settings.json`. Execution trace:
- Step 1: backs up original → .bak = original ✓
- Step 2: backs up post-step-1 → .bak = post-step-1 ✗ (original overwritten)
- Step 3: backs up post-step-2 → .bak = post-step-2 ✗
- Step 4: backs up post-step-3 → .bak = post-step-3 ✗
- Step 5: backs up post-step-4 → .bak = post-step-4 ✗

User cannot roll back to their pre-install state.

**Contrast:** `sync-permissions.sh`'s `write_settings` function (line 174) correctly uses `trap 'rm -f "$temp"' RETURN` for temp file safety.

## Proposed Solutions

### Option A — Single timestamped backup before any modification (recommended)

At the top of both installers, take exactly one backup of the original file:
```bash
if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
fi
```
Then remove the per-step `cp … .bak` calls, keeping only the `mv "$TEMP_N" "$SETTINGS"`.

**Pros:** Preserves original; timestamped so multiple install runs don't overwrite each other.
**Cons:** Creates a new backup file name format (but more useful than the current one).
**Effort:** small
**Risk:** low

### Option B — Take one non-timestamped backup at top only

Same as A but without timestamp: `cp "$SETTINGS" "${SETTINGS}.bak"`.

**Pros:** Simpler, consistent with existing `.bak` convention.
**Cons:** Re-running installer overwrites the backup, losing the original again.
**Effort:** trivial
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] Both `install.sh` and `setup-hooks.sh` take exactly one backup before any modifications begin
- [ ] Per-step backup `cp` calls are removed
- [ ] After a full install, the backup reflects the pre-install state of `settings.json`
- [ ] Tests verify backup is taken once and contains original content

## Work Log

### 2026-03-01 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

**Learnings:**
- Single pre-modification backup + timestamped name is the correct pattern

### 2026-02-28 — Security audit finding

**By:** Claude Code (security-sentinel agent)

**Actions:**
- Traced all 5 backup points in install.sh and setup-hooks.sh
- Confirmed each step overwrites .bak with the post-previous-step state
- Identified correct pattern from sync-permissions.sh write_settings

**Learnings:**
- Per-step backup is an anti-pattern when steps are sequential modifications of the same file
- A single pre-modification snapshot is the correct approach
