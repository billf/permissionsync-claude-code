---
status: ready
priority: p1
issue_id: "009"
tags: [watch-config, config-change, blocking, set-e]
dependencies: []
---

# `set -euo pipefail` + unguarded eval can block ConfigChange events

## Problem Statement

`permissionsync-watch-config.sh` uses `set -euo pipefail`. Claude Code's `ConfigChange` hook type can **block** a config change from taking effect if the hook script exits non-zero. The unguarded `eval "$(jq -r ...)"` on line 6 can exit non-zero before reaching the final `exit 0`, causing Claude Code to reject the user's config change.

## Findings

**File:** `permissionsync-watch-config.sh` lines 3 and 6

```bash
set -euo pipefail
...
eval "$(jq -r '@sh "SOURCE=\(.source // "") FILE_PATH=\(.file_path // "") SESSION_ID=\(.session_id // "") CWD=\(.cwd // "")"' <<<"$INPUT")"
```

**Failure modes that abort before `exit 0`:**
- `jq` not found on PATH → command exits 127
- stdin is not valid UTF-8 → `jq` parse error, exits 5
- Any future unbound variable reference → exits 1 under `set -u`

The `2>/dev/null || echo 0` guards on lines 20–21 protect the subsequent jq calls, but line 6 is unguarded. `set -e` will then abort the script, returning its non-zero exit code to Claude Code, which treats this as "block the ConfigChange."

**By contrast:** `permissionsync-log-hook-errors.sh` has the same `eval` pattern (line 12) but its hook type (`PostToolUseFailure`) is non-blocking regardless of exit code.

**Intended behavior:** The hook is explicitly designed as warn-only. It should never block a config change. The current `exit 0` at the end is correct, but `set -e` can prevent it from being reached.

## Proposed Solutions

### Option A — `trap 'exit 0' ERR` safety net (recommended)

Add a trap near the top of the script to ensure any unexpected error still exits 0:
```bash
set -euo pipefail
trap 'exit 0' ERR  # warn-only hook: never block config changes
```

**Pros:** Simple one-liner. Explicitly documents intent. Preserves `set -e` for early error detection during normal operation.
**Cons:** Masks errors that happen to fire the trap — though these are already undetectable since the hook is fire-and-forget.
**Effort:** trivial
**Risk:** low

### Option B — Wrap body in subshell with `|| true`

```bash
main() {
    # ... all existing logic ...
}
main || true
```

**Pros:** Body retains `set -e` error detection; outer `|| true` ensures exit 0.
**Cons:** More structural change; slightly less readable.
**Effort:** small
**Risk:** low

### Option C — Guard the eval with `|| true`

```bash
eval "$(jq -r '@sh ...' <<<"$INPUT")" || true
```

**Pros:** Targeted fix at the specific failure point.
**Cons:** Only fixes the eval; other unguarded commands could still trigger `set -e`.
**Effort:** trivial
**Risk:** medium (leaves other potential abort paths)

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] `permissionsync-watch-config.sh` cannot exit non-zero under any input condition
- [ ] If `jq` is missing or stdin is malformed, the script exits 0 (warn-only)
- [ ] Test case: malformed JSON on stdin → script exits 0, no output to stdout
- [ ] Test case: `jq` not found → script exits 0 (stub jq that exits 127)

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Architecture review finding

**By:** Claude Code (architecture-strategist agent)

**Actions:**
- Identified ConfigChange hook type blocks on non-zero exit
- Traced path from `set -euo pipefail` through unguarded eval to abort-before-exit-0
- Confirmed `log-hook-errors.sh` is safe (PostToolUseFailure is non-blocking)

**Learnings:**
- Hook type semantics matter: ConfigChange is blocking, PostToolUseFailure is not
- `set -euo pipefail` in a blocking hook requires an explicit exit-0 safety net
- Warn-only hooks should always have an unconditional `exit 0` that cannot be short-circuited
