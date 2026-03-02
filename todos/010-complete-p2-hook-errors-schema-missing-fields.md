---
status: complete
priority: p2
issue_id: "010"
tags: [schema, hook-errors, jsonl, is-safe, indirection-chain]
dependencies: []
---

# hook-errors.jsonl omits is_safe and indirection_chain fields

## Problem Statement

`permissionsync-log-hook-errors.sh` emits `hook-errors.jsonl` records that omit `is_safe` and `indirection_chain` fields present in `confirmed-approvals.jsonl`. Both scripts call `build_rule_v2` identically, which sets `IS_SAFE` and `INDIRECTION_CHAIN` as local variables — but the errors script never passes them to `jq`. This is an oversight, not intentional design: the errors log is the one place where knowing whether a failed tool was "safe" or involved indirection is most valuable for security analysis.

## Findings

**Affected file:** `permissionsync-log-hook-errors.sh` lines 19–26

Current output schema:
```json
{"timestamp": "...", "tool": "...", "rule": "...", "base_command": "...",
 "error": "...", "error_message": "...", "cwd": "...", "session_id": "..."}
```

Reference schema (`confirmed-approvals.jsonl` via `log-confirmed.sh` lines 34–44):
```json
{"timestamp": "...", "tool": "...", "rule": "...", "base_command": "...",
 "indirection_chain": "...", "is_safe": "...", "cwd": "...", "session_id": "..."}
```

`build_rule_v2` is called identically in both scripts (log-confirmed.sh line 30, hook-errors.sh line 16). After the call, `INDIRECTION_CHAIN` and `IS_SAFE` are set in scope but never referenced in `permissionsync-log-hook-errors.sh`.

**Test gap:** `tests/test-permissionsync-log-hook-errors.sh` validates present fields but does not assert the absence or presence of `is_safe`/`indirection_chain`.

## Proposed Solutions

### Option A — Add missing fields to jq output (recommended)

In `permissionsync-log-hook-errors.sh`, change the jq call to include both fields:
```bash
jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tool "$TOOL_NAME" \
    --arg rule "$RULE" \
    --arg base_command "$BASE_COMMAND" \
    --arg indirection_chain "$INDIRECTION_CHAIN" \
    --arg is_safe "$IS_SAFE" \
    --arg error "$ERROR_TYPE" \
    --arg error_message "$ERROR_MSG" \
    --arg cwd "$CWD" \
    --arg session_id "$SESSION_ID" \
    '{timestamp:$ts, tool:$tool, rule:$rule, base_command:$base_command,
      indirection_chain:$indirection_chain, is_safe:$is_safe,
      error:$error, error_message:$error_message, cwd:$cwd, session_id:$session_id}'
```

**Pros:** Consistent schema across all JSONL logs; enables security queries across error events.
**Cons:** Minor schema change — existing consumers parsing hook-errors.jsonl will see new fields (additive, backward-compatible).
**Effort:** trivial
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] `permissionsync-log-hook-errors.sh` emits `is_safe` and `indirection_chain` in output
- [ ] Test in `test-permissionsync-log-hook-errors.sh` verifies both fields are present
- [ ] Schema is consistent with `confirmed-approvals.jsonl`

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Pattern review finding

**By:** Claude Code (pattern-recognition-specialist agent)

**Actions:**
- Compared jq output between log-confirmed.sh and permissionsync-log-hook-errors.sh
- Confirmed both call build_rule_v2 identically but errors script drops the resulting fields
- Identified that variables are set in scope but not used

**Learnings:**
- Schema consistency across JSONL logs matters for unified security analysis
- Missing fields in error logs reduce debuggability exactly when it matters most
