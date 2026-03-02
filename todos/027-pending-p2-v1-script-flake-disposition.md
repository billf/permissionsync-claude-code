---
status: pending
priority: p2
issue_id: "027"
tags: [architecture, code-review, nix, flake]
dependencies: []
---

# Ambiguous Disposition of permissionsync-log-permission-v1.sh in Nix Flake

## Problem Statement

`permissionsync-log-permission-v1.sh` is listed in `executableScripts` in `flake.nix`, which means it gets a `makeWrapper`-wrapped binary in `$out/bin/` with `PERMISSIONSYNC_LIB_DIR` set. However, both `permissionsync-install.sh` and `permissionsync-setup.sh` explicitly say it is "not installed — eviction-list only". The result: a wrapped binary is on PATH in Nix installs that no installer will ever wire into `settings.json`.

Additionally, the eviction list in both installers does not cover the case where a user manually wired `$HOOKS_DIR/permissionsync-log-permission-v1.sh` — re-running the installer would leave that entry alongside the new one, creating duplicate PermissionRequest hooks.

## Findings

- `flake.nix` line 19: `permissionsync-log-permission-v1.sh` in `executableScripts` — gets wrapped binary in `$out/bin/`
- `permissionsync-install.sh` line 59: "not copied — eviction-list only"
- `permissionsync-setup.sh` line 61: "not installed — eviction-list only"
- Neither installer's MANAGED_ eviction list includes `$HOOKS_DIR/permissionsync-log-permission-v1.sh` as a variant to evict
- If a Nix user wires `permissionsync-log-permission-v1.sh` manually, re-install creates duplicates

## Proposed Solutions

### Option A: Keep in executableScripts but add to eviction list (Recommended)

Add `MANAGED_V1_CMD="$HOOKS_DIR/permissionsync-log-permission-v1.sh"` to both installers' MANAGED_ lists and include it in the jq eviction filter. This closes the duplicate-hook gap with minimal change.

- **Pros**: Covers the edge case; v1 binary remains available for users who want log-only mode without env-var
- **Cons**: Adds one more MANAGED_ variable (but todo 021/simplicity review suggests collapsing these anyway)
- **Effort**: Small
- **Risk**: Low

### Option B: Remove from executableScripts in flake.nix

Keep the file in the repo as documentation but remove it from the `executableScripts` list. It won't get a wrapped binary — it becomes a source-only reference. Add a comment in flake.nix explaining why.

- **Pros**: Architecturally cleaner — resolves the "in bin but never installed" ambiguity
- **Cons**: Users who want log-only mode must use `CLAUDE_PERMISSION_MODE=log` with the main script (which is already documented)
- **Effort**: Trivial
- **Risk**: Low

### Option C: Document the intended use case explicitly

Add a comment to the v1 file and the installer explaining when a user would choose v1 vs. the main script with `MODE=log`.

## Recommended Action

Option A if the plan is to support v1 as an explicit choice for users. Option B if v1 is purely historical documentation. The simplest path is Option B — users who want log-only mode already have `CLAUDE_PERMISSION_MODE=log permissionsync-log-permission.sh`. The v1 file adds no capability that isn't already available.

## Technical Details

- **Affected Files**: `flake.nix` (executableScripts list), `permissionsync-install.sh` (MANAGED_ list), `permissionsync-setup.sh` (MANAGED_ list)

## Acceptance Criteria

- [ ] Either: v1 script removed from executableScripts in flake.nix (Option B)
- [ ] Or: v1 script added to MANAGED_ eviction list in both installers (Option A)
- [ ] No duplicate PermissionRequest hooks created by re-running installer on a system where v1 was manually wired
- [ ] Tests pass

## Work Log

### 2026-03-02 - Identified in architecture review

**By:** Architecture review agent
