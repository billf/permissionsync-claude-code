---
status: ready
priority: p2
issue_id: "014"
tags: [session-end, sync-on-end, reason, clear, behavior]
dependencies: ["006"]
---

# sync-on-end syncs unconditionally on reason=clear — may promote aborted-session rules

## Problem Statement

`permissionsync-sync-on-end.sh` discards the `reason` field from the `SessionEnd` event and always runs sync. When a user issues `/clear` in Claude Code, the hook fires with `reason="clear"` — the session is being reset, not completed. Syncing at this point promotes any rules accumulated in the cleared session into the permanent `settings.json` allow list, against the user's intent.

## Findings

**File:** `permissionsync-sync-on-end.sh` lines 6–7

```bash
# Read stdin (reason field) but don't use it — sync regardless
true </dev/stdin
```

The `SessionEnd` hook fires for at least two reasons:
- `reason="clear"` → user ran `/clear`, resetting the session
- `reason="end"` (or similar) → session completed normally

On `/clear`, the user may have accumulated partial tool approvals in an explorative/experimental session they're intentionally discarding. Syncing at this point promotes those rules permanently.

**Additional concern:** this compounds with Finding 006 (wrong log source). Even with 006 fixed, syncing on `/clear` is the wrong behavior if the user is discarding the session.

**Test gap:** `tests/test-permissionsync-sync-on-end.sh` only tests `reason="clear"` (line 74: `run_hook "clear"`). There is no test for normal session end or for the filtering decision.

Note: This is a behavioral decision — the team should verify what values Claude Code actually sends for `reason` on normal session end vs. `/clear`.

## Proposed Solutions

### Option A — Skip sync on reason=clear (recommended)

Parse the reason field and skip sync when clearing:
```bash
INPUT=$(</dev/stdin)
REASON=$(jq -r '.reason // ""' <<<"$INPUT")

if [[ "$REASON" == "clear" ]]; then
    exit 0  # don't sync on session clear
fi

"$SYNC" --from-confirmed --apply >/dev/null 2>&1 || true
```

**Pros:** Clear semantic: only sync when session truly ends, not when user resets.
**Cons:** Requires knowing Claude Code's exact reason values for normal end.
**Effort:** small
**Risk:** low

### Option B — Keep current behavior but document it explicitly

Update the comment to explicitly document the decision:
```bash
# Sync on all session events including /clear.
# This promotes rules even from cleared sessions.
# If this causes issues, filter on reason=="end".
true </dev/stdin
```

**Pros:** No code change; addresses ambiguity only in documentation.
**Cons:** Still promotes rules from cleared sessions.
**Effort:** trivial
**Risk:** low (maintains current behavior)

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] Team decision documented: sync on `clear` yes/no
- [ ] If skipping: script reads and checks `reason` field before running sync
- [ ] Tests cover both `reason="clear"` and `reason="end"` (or equivalent)
- [ ] stdin is consumed via `INPUT=$(</dev/stdin)` consistent with project pattern (see also todo 018)

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Architecture review finding

**By:** Claude Code (architecture-strategist agent)

**Actions:**
- Identified unconditional sync regardless of session end reason
- Noted test only covers reason=clear with no coverage of normal end
- Identified dependency on todo 006 (wrong log source) as compounding factor

**Learnings:**
- SessionEnd hook semantics require understanding when Claude Code sends each reason value
- Verify Claude Code API docs for complete list of SessionEnd reason values
