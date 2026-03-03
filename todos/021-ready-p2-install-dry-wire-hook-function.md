---
status: complete
priority: p2
issue_id: "021"
tags: [install, setup-hooks, dry, refactor, wire-hook, shared-lib]
dependencies: []
---

# DRY install/setup-hooks: extract wire_simple_hook() + shared lib

## Problem Statement

`install.sh` and `setup-hooks.sh` have two overlapping DRY violations:

1. **TEMP2–TEMP5 proliferation:** Both files repeat an identical jq+mktemp+cmp+mv pattern 4 times for steps 4–7. A `wire_simple_hook()` function would collapse ~280 lines to ~70.
2. **Shared logic duplicated verbatim:** `seed_baseline_permissions()`, 6 `MANAGED_*_CMD` variables, and the complex PermissionRequest jq filter (~60 lines) are copy-pasted between both files. Any future hook change requires updating two files.
3. **No legacy-eviction mechanism for non-PermissionRequest hooks:** If any of the 6 non-PermissionRequest hook scripts are ever renamed, the old command path accumulates silently in `settings.json` and fires (failing silently) on every matching event. Only PermissionRequest has a `MANAGED_*_CMD` list for handling this. `wire_simple_hook()` must accept variadic legacy commands to evict, making rename safety the default.

Combined fix: extract `wire_simple_hook()` with legacy eviction + shared functions into a `permissionsync-install-lib.sh` sourced by both installers.

**Historical note:** Full git history confirmed — zero scripts have ever been renamed. No cleanup of existing `settings.json` files is needed today. The risk is purely forward-looking.

## Findings

**Files:** `install.sh` lines 164–280, `setup-hooks.sh` lines 164–280

Each of the 4 repetitions:
1. Declares a `TEMPn` variable via `mktemp`
2. Runs `jq` with a near-identical filter (only event name, `$cmd`, matcher differ)
3. Compares with `cmp`, promotes or cleans up
4. Emits success echo

Estimated ~70 lines per file, 280 lines total across both files. A `wire_simple_hook(hook_event, cmd, matcher, label)` function would collapse this to ~15 lines (function) + 4 call sites (~20 lines), saving ~240 lines across both files.

**Proposed function signature (with variadic legacy eviction):**
```bash
# wire_simple_hook EVENT CMD MATCHER LABEL [OLD_CMD...]
# Removes OLD_CMDs and CMD from the event's hook list, then adds CMD back.
# This handles renames: pass old script paths as OLD_CMD args.
wire_simple_hook() {
    local hook_event="$1" cmd="$2" matcher="$3" label="$4"
    shift 4
    local old_cmds=("$@")  # variadic legacy commands to evict

    # Build jq args for all commands to remove (current + legacy)
    local jq_args=(--arg cmd "$cmd" --arg matcher "$matcher" --arg event "$hook_event")
    local evict_filter='.command != $cmd'
    local i=0
    for old in "${old_cmds[@]}"; do
        jq_args+=(--arg "old${i}" "$old")
        evict_filter+=" and .command != \$old${i}"
        ((i++)) || true
    done

    local tmp
    tmp=$(mktemp)
    _TEMPS+=("$tmp")
    if ! jq "${jq_args[@]}" "
        .hooks //= {} |
        .hooks[\$event] //= [] |
        .hooks[\$event] = (
          [ .hooks[\$event][]
            | .hooks = ((.hooks // []) | map(select(${evict_filter})))
            | select((.hooks | length) > 0)
          ] + [{ matcher: \$matcher, hooks: [{type: \"command\", command: \$cmd}] }]
        )
    " "$SETTINGS" >"$tmp"; then
        echo "ERROR: Failed to wire ${hook_event} hook in $SETTINGS"
        exit 1
    fi
    if ! cmp -s "$SETTINGS" "$tmp"; then
        cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
        mv "$tmp" "$SETTINGS"
        echo "✓ Wired ${hook_event} hook (${label})"
    fi
}
```

Call sites (current, no legacy cmds needed today since no scripts have been renamed):
```bash
wire_simple_hook "PostToolUse"        "$HOOKS_DIR/log-confirmed.sh"                   "*"             "confirmed-approvals log"
wire_simple_hook "PostToolUseFailure" "$HOOKS_DIR/permissionsync-log-hook-errors.sh"  "*"             "hook-errors log"
wire_simple_hook "ConfigChange"       "$HOOKS_DIR/permissionsync-watch-config.sh"     "user_settings" "config-changes log"
wire_simple_hook "SessionEnd"         "$HOOKS_DIR/permissionsync-sync-on-end.sh"      "*"             "auto-sync on exit"
```

If a script is renamed in the future, add the old path as a trailing arg:
```bash
# Example: log-confirmed.sh renamed to log-approved.sh
wire_simple_hook "PostToolUse" "$HOOKS_DIR/log-approved.sh" "*" "confirmed-approvals log" \
    "$HOOKS_DIR/log-confirmed.sh"   # ← old name, evicted on reinstall
```

Note: `ConfigChange` uses `matcher: "user_settings"` (confirmed in install.sh line 239).

## Proposed Solutions

### Option A — Full shared lib (recommended, merges former todo 022)

Create `permissionsync-install-lib.sh` containing:
- `seed_baseline_permissions()`
- `wire_simple_hook()`
- `wire_permission_request_hook()`
- The `MANAGED_*_CMD` variable block

Both `install.sh` and `setup-hooks.sh` source it. Eliminates ~430 lines of duplication (~240 wire_simple_hook + ~150 shared logic + 40 seed).

**Effort:** large
**Risk:** medium (careful testing of both installers; Nix flake packaging implications)

### Option B — wire_simple_hook in each file independently (incremental step)

Extract only the function in-place without the shared lib. Defers the broader DRY work.

**Effort:** medium
**Risk:** low

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] `wire_simple_hook()` extracted (in shared lib or per-file) with variadic legacy-eviction args
- [ ] All hook-wiring repetitions (steps 4–9 in install.sh) replaced with function calls
- [ ] TEMP2–TEMP7 variable names eliminated
- [ ] `seed_baseline_permissions()` and `MANAGED_*_CMD` block deduplicated (shared lib)
- [ ] PermissionRequest jq filter deduplicated (shared lib)
- [ ] Renaming any hook script only requires adding the old path as a trailing arg — no bespoke migration code
- [ ] Both `install.sh` and `setup-hooks.sh` tests pass
- [ ] `shfmt` and `shellcheck` clean on all modified files
- [ ] Nix flake includes shared lib in package output

## Work Log

### 2026-03-02 — Updated: legacy eviction design added

**By:** Claude Code

**Actions:**
- Full git history searched — zero script renames ever, no settings.json cleanup needed
- Problem statement expanded to include rename-safety as a core requirement
- `wire_simple_hook()` signature updated to accept variadic legacy commands to evict
- Acceptance criteria updated to cover legacy eviction
- Noted install.sh currently goes to TEMP7 (9 steps, not 4)

**Learnings:**
- `PermissionRequest` already handles legacy eviction via MANAGED_*_CMD list; the new function should generalize this for all hook types
- No historical debt, but the pattern must be established before any future rename

### 2026-03-02 — Triage approved (elevated P3 → P2, merged with former #022)

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Priority elevated: p3 → p2 (~280 lines of duplication compounds with every new hook)
- Status changed from pending → ready

### 2026-02-28 — Code simplicity review finding

**By:** Claude Code (code-simplicity-reviewer agent)

**Actions:**
- Identified 4 repetitions of identical jq+mktemp+cmp+mv pattern across 2 files
- Estimated ~240 lines of duplication reducible to ~70 lines
- Designed wire_simple_hook function signature

**Learnings:**
- Repeated patterns with only parameterized differences are always function candidates
- TEMP2/TEMP3/TEMP4/TEMP5 naming is a code smell indicating missing abstraction
