---
status: complete
priority: p2
issue_id: "012"
tags: [install, temp-files, cleanup, trap, setup-hooks]
dependencies: []
---

# No EXIT trap for orphaned temp files in install.sh and setup-hooks.sh

## Problem Statement

Both `install.sh` and `setup-hooks.sh` use `set -euo pipefail` but have no `EXIT` trap to clean up temp files. If any command between a successful `mktemp` and the final `mv`/`rm` exits non-zero, `set -e` terminates the script and temp files containing a copy of `settings.json` are orphaned in `/tmp`.

## Findings

**Files:** `install.sh` lines 113, 164, 194, 224, 254 (and `seed_baseline_permissions` at line 45); `setup-hooks.sh` same pattern.

The scripts create up to 6 temp files (`TEMP`, `TEMP2`–`TEMP5`, plus one inside `seed_baseline_permissions`). Each is created with:
```bash
TEMP2=$(mktemp)
```

Cleanup only happens on success paths:
```bash
else
    rm -f "$TEMP2"  # only if cmp shows no change
fi
```

Or on the explicit error path:
```bash
if ! jq ...; then
    rm -f "$TEMP2"
    exit 1
fi
```

The gap: if `cmp` fails with exit code 2 (I/O error), or any other unexpected failure after the jq write succeeds, `set -e` fires and orphans the temp file.

**No confidentiality risk:** `mktemp` on macOS creates `0600` files. However, the orphaned files contain a copy of `settings.json` with hook command paths and permission allow lists.

**Reference:** `sync-permissions.sh`'s `write_settings` function (line 174) uses `trap 'rm -f "$temp"' RETURN` — the correct pattern.

## Proposed Solutions

### Option A — Accumulating EXIT trap (recommended)

At the top of each installer, declare an accumulating temp array and EXIT trap:
```bash
_TEMPS=()
trap 'rm -f "${_TEMPS[@]}"' EXIT

# Then after each mktemp:
TEMP2=$(mktemp); _TEMPS+=("$TEMP2")
```

**Pros:** Comprehensive cleanup regardless of failure point. Matches `sync-permissions.sh` pattern.
**Cons:** Slightly more setup boilerplate.
**Effort:** small
**Risk:** low

### Option B — Individual RETURN traps per function

Refactor each step into a function and use `trap 'rm -f "$TEMP_N"' RETURN`.

**Pros:** More granular cleanup.
**Cons:** Requires the DRY refactor (see todo 021) first for it to be worthwhile.
**Effort:** medium
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] Both `install.sh` and `setup-hooks.sh` register an `EXIT` trap that removes all temp files
- [ ] Temp files are cleaned up even if the script aborts mid-run
- [ ] The `seed_baseline_permissions` temp file is also covered

## Work Log

### 2026-03-02 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready

### 2026-02-28 — Security audit finding

**By:** Claude Code (security-sentinel agent)

**Actions:**
- Identified all mktemp call sites in install.sh and setup-hooks.sh
- Confirmed no EXIT trap exists
- Found reference pattern in sync-permissions.sh write_settings

**Learnings:**
- Any script using set -euo pipefail that creates temp files needs an EXIT trap
- The cleanup pattern from sync-permissions.sh should be the project standard
