---
status: complete
priority: p1
issue_id: "023"
tags: [security, code-review, environment, injection]
dependencies: []
---

# PSEC-02: PERMISSIONSYNC_LIB_DIR Sourced Without Validation

## Problem Statement

Every hook script sources its library via:
```bash
source "${PERMISSIONSYNC_LIB_DIR:-$SCRIPT_DIR/lib}/permissionsync-lib.sh"
```

`PERMISSIONSYNC_LIB_DIR` is never validated. An attacker who can set this env var (e.g., via a repo's `.envrc` loaded by `direnv`) can point it at a directory containing a malicious `permissionsync-lib.sh`. The source executes with full user privileges the moment any Claude Code permission request fires.

**Attack vector:** Malicious repo ships `.envrc` with `export PERMISSIONSYNC_LIB_DIR=/tmp/attacker-lib`. Developer `cd`s into repo, direnv auto-loads it, then runs `claude`. First permission prompt → hook fires → arbitrary code executes.

## Findings

- All hook scripts: `permissionsync-log-permission.sh:25`, `permissionsync-log-confirmed.sh:17`, `permissionsync-log-hook-errors.sh`, `permissionsync-session-start.sh`, `permissionsync-worktree-create.sh`, `permissionsync-watch-config.sh` (no lib), `permissionsync-sync-on-end.sh`
- `PERMISSIONSYNC_LIB_DIR` is intended to be set by Nix `makeWrapper --set` — a build-time constant, not a runtime user-settable var
- But as an env var, it's inheritable by any child process and overridable by `direnv`/`export` in shell environments

## Proposed Solutions

### Option 1: Validate PERMISSIONSYNC_LIB_DIR against trusted prefixes (Recommended)

```bash
_PSC_LIB="${SCRIPT_DIR}/lib"
if [[ -n ${PERMISSIONSYNC_LIB_DIR:-} ]]; then
    case "$PERMISSIONSYNC_LIB_DIR" in
        "$HOME/.claude/hooks/lib"|"/nix/store/"*)
            _PSC_LIB="$PERMISSIONSYNC_LIB_DIR" ;;
        *)
            echo "permissionsync: ignoring untrusted PERMISSIONSYNC_LIB_DIR" >&2 ;;
    esac
fi
source "${_PSC_LIB}/permissionsync-lib.sh"
```

- **Pros**: Preserves the Nix override capability; blocks arbitrary paths
- **Cons**: Nix store path starts with `/nix/store/` which is safe and fixed
- **Effort**: Small (same boilerplate in each hook script)
- **Risk**: Low

### Option 2: Ignore PERMISSIONSYNC_LIB_DIR in runtime hook scripts entirely

Remove the env-var check from hook scripts; use only `$SCRIPT_DIR/lib`. Keep `PERMISSIONSYNC_LIB_DIR` support only in worker scripts (sync, settings, launch) where it is less exposed.

- **Pros**: Simplest fix for the highest-risk scripts (hooks fire on every permission request)
- **Cons**: Nix would need to patch hooks differently (or the installed hooks use $SCRIPT_DIR/lib from ~/.claude/hooks/lib which is always correct for both dev and manual installs)
- **Effort**: Small
- **Risk**: Low — the `$SCRIPT_DIR/lib` fallback already works correctly in dev, Nix (hooks land in ~/.claude/hooks/ which has lib/ subdir), and manual install

### Option 3: Rename to PERMISSIONSYNC_LIB_DIR_NIXED and only honor it if it matches Nix store pattern

Not worth the complexity — Option 1 or 2 covers the need.

## Recommended Action

Option 2 for hook scripts (the ones that fire on every permission request). They already work correctly via `$SCRIPT_DIR/lib` in all three deployment contexts (dev, Nix-installed to ~/.claude/hooks/, manual install). The env-var override is only needed for the Nix wrapping, which sets it as a build-time constant — but since hooks get copied to `~/.claude/hooks/` with `lib/` alongside them, `$SCRIPT_DIR/lib` is always correct.

Option 1 for worker scripts (permissionsync-sync.sh, permissionsync-settings.sh, permissionsync-launch.sh, permissionsync-worktree-sync.sh) where the env-var override is more legitimately needed.

## Technical Details

- **Affected Files**: All scripts with `source "${PERMISSIONSYNC_LIB_DIR:-$SCRIPT_DIR/lib}/permissionsync-lib.sh"`
- **Highest risk**: `permissionsync-log-permission.sh` (fires on every PermissionRequest)
- **Related**: `flake.nix` `makeWrapper --set PERMISSIONSYNC_LIB_DIR` line

## Acceptance Criteria

- [ ] Hook scripts (`permissionsync-log-permission.sh`, `permissionsync-log-confirmed.sh`, `permissionsync-log-hook-errors.sh`, `permissionsync-session-start.sh`, `permissionsync-worktree-create.sh`, `permissionsync-sync-on-end.sh`) do not honor arbitrary `PERMISSIONSYNC_LIB_DIR` values
- [ ] Nix install still works (hooks use `$SCRIPT_DIR/lib` which resolves to `~/.claude/hooks/lib/`)
- [ ] Dev install still works (same fallback)
- [ ] shellcheck passes
- [ ] All tests pass

## Work Log

### 2026-03-02 - Identified in code review

**By:** Security review agent

**Actions:**
- Confirmed env var is set only by Nix makeWrapper at build time
- Confirmed that $SCRIPT_DIR/lib is always the correct path in dev, Nix hook install, and manual install contexts
- Option 2 (remove env-var from hook scripts) is safer and simpler

## Resources

- `flake.nix` makeWrapper --set PERMISSIONSYNC_LIB_DIR line
- direnv docs on .envrc auto-loading
