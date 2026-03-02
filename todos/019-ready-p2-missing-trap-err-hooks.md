---
status: ready
priority: p2
issue_id: "019"
tags: [hook-errors, watch-config, sync-on-end, trap, error-reporting]
dependencies: []
---

# Missing trap ERR for self-failure reporting in all 3 new hook scripts

## Problem Statement

None of the 3 new hook scripts has a `trap ERR` handler that logs their own failures. If any hook encounters an unexpected error (bad stdin, missing dependency, disk full), the failure is silent. `permissionsync-log-hook-errors.sh` has the ironic situation: the script whose job is to record tool failures has no mechanism to record its own failure.

## Findings

**Files:**
- `permissionsync-log-hook-errors.sh` — no trap ERR
- `permissionsync-watch-config.sh` — no trap ERR
- `permissionsync-sync-on-end.sh` — no trap ERR

The existing original hooks (`log-permission-auto.sh`, `log-permission.sh`) also don't use this pattern, so this is a new improvement opportunity rather than a regression.

**Minimal pattern:**
```bash
trap 'echo "[permissionsync] hook failed at line $LINENO: $BASH_COMMAND" >&2' ERR
```

More robust version that writes to the project's error log:
```bash
trap '_hook_self_error "$LINENO" "$BASH_COMMAND"' ERR

_hook_self_error() {
    local lineno="$1" cmd="$2"
    jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg script "${BASH_SOURCE[0]}" \
        --arg lineno "$lineno" \
        --arg cmd "$cmd" \
        '{timestamp:$ts, error:"hook_self_error", script:$script, lineno:$lineno, command:$cmd}' \
        >> "$ERRORS_LOG" 2>/dev/null || true
}
```

Note: For `permissionsync-watch-config.sh`, any `trap ERR` must still result in `exit 0` (see todo 009).

## Proposed Solutions

### Option A — Minimal stderr trap (recommended for now)

Add `trap 'echo "[permissionsync] $0 failed at line $LINENO" >&2' ERR` to all 3 scripts.

**Effort:** trivial
**Risk:** low

### Option B — Log to hook-errors.jsonl

More structured self-error reporting, writing a structured record.

**Effort:** medium
**Risk:** low (but more infrastructure)

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] All 3 hook scripts have a `trap ERR` that emits a diagnostic
- [ ] For `watch-config.sh`, trap still ensures `exit 0` after logging (per todo 009)
- [ ] Diagnostic is distinguishable from normal output

## Work Log

### 2026-03-02 — Triage approved (elevated P3 → P2)

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Priority elevated: p3 → p2 (irony of log-hook-errors.sh having no self-error reporting)
- Status changed from pending → ready

### 2026-02-28 — Architecture review finding

**By:** Claude Code (architecture-strategist agent)

**Actions:**
- Identified absence of ERR traps in all 3 new hook scripts
- Noted the irony of log-hook-errors.sh having no self-error reporting
- Considered interaction with watch-config.sh's blocking behavior (todo 009)

**Learnings:**
- Hook scripts are best-effort side effects but should still surface their own failures
- `trap ERR` is cheap and provides minimal observability for debugging
