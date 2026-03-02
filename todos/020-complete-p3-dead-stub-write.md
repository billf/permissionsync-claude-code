---
status: complete
priority: p3
issue_id: "020"
tags: [tests, sync-on-end, dead-code, cleanup]
dependencies: []
---

# Dead first stub write in test-permissionsync-sync-on-end.sh

## Problem Statement

`tests/test-permissionsync-sync-on-end.sh` writes the `sync-permissions.sh` stub twice in sequence. The first write (single-quoted heredoc) produces a script with literal unexpanded `${INVOCATIONS_LOG}`, which would fail at runtime. It is immediately overwritten by a correct second write. The first write is dead code.

## Findings

**File:** `tests/test-permissionsync-sync-on-end.sh` lines 49–62

```bash
# First write — dead code (single-quoted heredoc: ${INVOCATIONS_LOG} is literal)
cat >"${STUB_DIR}/sync-permissions.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${INVOCATIONS_LOG}"
exit 0
STUB
# Export log path for stub
export INVOCATIONS_LOG
# Patch stub to use the exported variable — OVERWRITES the first write
cat >"${STUB_DIR}/sync-permissions.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$INVOCATIONS_LOG"
exit 0
STUB
```

The comment "Patch stub to use the exported variable" suggests this was a deliberate second pass, but in reality it simply replaces the entire file. The first write never serves a purpose. Tests pass because the second write is correct.

## Proposed Solutions

### Option A — Remove the first write (recommended)

Delete lines 49–55 (the first `cat >...<<'STUB'` block and its `STUB` terminator). Keep the `export INVOCATIONS_LOG` and the second write.

**Effort:** trivial (delete 6 lines)
**Risk:** none

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] `tests/test-permissionsync-sync-on-end.sh` stub is written exactly once
- [ ] The `export INVOCATIONS_LOG` line precedes the single write
- [ ] All tests in the file still pass

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Code simplicity review finding (confirmed by architecture agent)

**By:** Claude Code (code-simplicity-reviewer + architecture-strategist agents)

**Actions:**
- Identified double stub write in test-permissionsync-sync-on-end.sh
- Confirmed first write produces broken script (unexpanded variable)
- Confirmed second write is correct and sufficient

**Learnings:**
- Dead code in test setup is confusing and suggests an incomplete refactor
- Single-quoted heredocs don't expand variables — easy source of silent bugs
