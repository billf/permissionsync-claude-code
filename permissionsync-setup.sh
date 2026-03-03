#!/usr/bin/env bash
# permissionsync-setup.sh — idempotent hook installer for use in Nix flake shellHooks
#
# Copies permissionsync-cc scripts to ~/.claude/hooks/ and ensures the
# PermissionRequest hook is configured in ~/.claude/settings.json.
#
# Designed to run on every shell entry: uses cmp(1) to skip unchanged files,
# checks settings.json before modifying, and produces no output when nothing
# changes.
#
# Usage:
#   permissionsync-setup.sh              # log-only mode (default)
#   permissionsync-setup.sh auto         # auto-approve previously-seen rules
#   permissionsync-setup.sh worktree     # auto-approve + sibling worktree rules
#
# When called from a Nix flake shellHook:
#   ${psc}/bin/permissionsync-setup.sh            # log mode
#   ${psc}/bin/permissionsync-setup.sh auto       # auto mode
#   ${psc}/bin/permissionsync-setup.sh worktree   # worktree mode

set -euo pipefail

# PERMISSIONSYNC_SHARE_DIR is patched by Nix to point to $out/share/permissionsync-cc
PERMISSIONSYNC_SHARE_DIR="${PERMISSIONSYNC_SHARE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# PERMISSIONSYNC_LIB_DIR is patched by Nix to point to $out/share/permissionsync-cc/lib
PERMISSIONSYNC_LIB_DIR="${PERMISSIONSYNC_LIB_DIR:-$PERMISSIONSYNC_SHARE_DIR/lib}"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
MODE="${1:-log}"

# shellcheck source=lib/permissionsync-install-lib.sh
source "${PERMISSIONSYNC_LIB_DIR}/permissionsync-install-lib.sh"

SCRIPTS=(
	# log-permission-v1.sh (formerly log-permission.sh) not installed — eviction-list only
	permissionsync-log-permission.sh
	permissionsync-log-confirmed.sh
	permissionsync-sync.sh
	permissionsync-worktree-sync.sh
	permissionsync-settings.sh
	permissionsync-launch.sh
	permissionsync.sh
	permissionsync-log-hook-errors.sh
	permissionsync-watch-config.sh
	permissionsync-sync-on-end.sh
	permissionsync-session-start.sh
	permissionsync-worktree-create.sh
)

LIB_SCRIPTS=(
	permissionsync-lib.sh
	permissionsync-config.sh
)

changed=0

# 1. Copy hook scripts and shared libraries (only when changed)
mkdir -p "$HOOKS_DIR" "$HOOKS_DIR/lib"
for s in "${LIB_SCRIPTS[@]}"; do
	if ! cmp -s "$PERMISSIONSYNC_LIB_DIR/$s" "$HOOKS_DIR/lib/$s" 2>/dev/null; then
		cp "$PERMISSIONSYNC_LIB_DIR/$s" "$HOOKS_DIR/lib/$s"
		changed=1
	fi
done
for s in "${SCRIPTS[@]}"; do
	if ! cmp -s "$PERMISSIONSYNC_SHARE_DIR/$s" "$HOOKS_DIR/$s" 2>/dev/null; then
		cp "$PERMISSIONSYNC_SHARE_DIR/$s" "$HOOKS_DIR/$s"
		chmod +x "$HOOKS_DIR/$s"
		changed=1
	fi
done

# 2. Determine hook command based on mode
resolve_hook_cmd "$MODE" "$HOOKS_DIR"
set_managed_cmds "$HOOKS_DIR"

# 3. Ensure settings.json exists
if [[ ! -f $SETTINGS ]]; then
	mkdir -p "$(dirname "$SETTINGS")"
	echo '{}' >"$SETTINGS"
	changed=1
fi

# 4. Wire all hooks (idempotent — each call evicts legacy names then adds current)
wire_hook "PermissionRequest" "$HOOK_CMD" "*" "permission logger" \
	"$MANAGED_LOG_CMD" "$MANAGED_V1_CMD" "$MANAGED_MODE_LOG_CMD" \
	"$MANAGED_AUTO_CMD" "$MANAGED_MODE_AUTO_CMD" \
	"$MANAGED_WORKTREE_CMD" "$MANAGED_MODE_WORKTREE_CMD" \
	"$MANAGED_NEW_MODE_LOG_CMD" "$MANAGED_NEW_MODE_AUTO_CMD" \
	"$MANAGED_NEW_MODE_WORKTREE_CMD" &&
	changed=1
wire_hook "PostToolUse" "$HOOKS_DIR/permissionsync-log-confirmed.sh" "*" "confirmed-approvals log" \
	"$HOOKS_DIR/log-confirmed.sh" &&
	changed=1
wire_hook "PostToolUseFailure" "$HOOKS_DIR/permissionsync-log-hook-errors.sh" "*" "hook-errors log" &&
	changed=1
wire_hook "ConfigChange" "$HOOKS_DIR/permissionsync-watch-config.sh" "user_settings" "config-changes log" &&
	changed=1
wire_hook "SessionEnd" "$HOOKS_DIR/permissionsync-sync-on-end.sh" "*" "auto-sync on exit" &&
	changed=1
wire_hook "SessionStart" "$HOOKS_DIR/permissionsync-session-start.sh" "" "drift notification" \
	"$HOOKS_DIR/session-start.sh" "$HOOKS_DIR/sync-permissions.sh --diff" &&
	changed=1
wire_hook "WorktreeCreate" "$HOOKS_DIR/permissionsync-worktree-create.sh" "" "settings seeding" \
	"$HOOKS_DIR/worktree-create.sh" &&
	changed=1

# 5. Seed baseline permissions (idempotent — skips if allow rules already exist)
seed_baseline_permissions "$HOOKS_DIR" "$SETTINGS"

# Report only when something changed
if [[ $changed -eq 1 ]]; then
	echo "permissionsync-cc: hooks installed ($MODE mode)"
fi
