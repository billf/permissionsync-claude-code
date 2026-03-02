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

# seed_baseline_permissions HOOKS_DIR SETTINGS
#
# Pre-seeds settings.json with curated safe-subcommand rules from config.
# Idempotent: skips if permissions.allow already has any entries.
seed_baseline_permissions() {
	local hooks_dir="$1" settings="$2"
	# shellcheck source=lib/permissionsync-lib.sh
	source "${hooks_dir}/lib/permissionsync-lib.sh"

	local existing_count
	existing_count=$(jq '.permissions.allow | length' "$settings" 2>/dev/null || echo 0)
	if [[ $existing_count -gt 0 ]]; then
		return 0 # Already has rules — skip seeding
	fi

	local rules_json
	rules_json=$(generate_baseline_rules | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')

	local tmp
	tmp=$(mktemp)
	jq --argjson rules "$rules_json" \
		'.permissions //= {} | .permissions.allow //= [] | .permissions.allow += $rules | .permissions.allow |= unique | .permissions.allow |= sort' \
		"$settings" >"$tmp" && mv "$tmp" "$settings"

	local count
	count=$(echo "$rules_json" | jq 'length')
	echo "permissionsync-cc: seeded $count baseline rules into settings.json"
}

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
case "$MODE" in
auto)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=auto $HOOKS_DIR/permissionsync-log-permission.sh"
	;;
worktree)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=worktree $HOOKS_DIR/permissionsync-log-permission.sh"
	;;
*)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=log $HOOKS_DIR/permissionsync-log-permission.sh"
	;;
esac
# All managed command patterns (legacy and current) — used to identify and
# replace previously-installed managed hook entries.
# Old script name (log-permission.sh):
MANAGED_LOG_CMD="$HOOKS_DIR/log-permission.sh"
# Old script name (log-permission-auto.sh):
MANAGED_MODE_LOG_CMD="CLAUDE_PERMISSION_MODE=log $HOOKS_DIR/log-permission-auto.sh"
MANAGED_AUTO_CMD="CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
MANAGED_MODE_AUTO_CMD="CLAUDE_PERMISSION_MODE=auto $HOOKS_DIR/log-permission-auto.sh"
MANAGED_WORKTREE_CMD="CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
MANAGED_MODE_WORKTREE_CMD="CLAUDE_PERMISSION_MODE=worktree $HOOKS_DIR/log-permission-auto.sh"
# Current script name (permissionsync-log-permission.sh):
MANAGED_NEW_MODE_LOG_CMD="CLAUDE_PERMISSION_MODE=log $HOOKS_DIR/permissionsync-log-permission.sh"
MANAGED_NEW_MODE_AUTO_CMD="CLAUDE_PERMISSION_MODE=auto $HOOKS_DIR/permissionsync-log-permission.sh"
MANAGED_NEW_MODE_WORKTREE_CMD="CLAUDE_PERMISSION_MODE=worktree $HOOKS_DIR/permissionsync-log-permission.sh"

# 3. Ensure settings.json has the PermissionRequest hook entry
if [[ ! -f $SETTINGS ]]; then
	mkdir -p "$(dirname "$SETTINGS")"
	echo '{}' >"$SETTINGS"
	changed=1
fi

TEMP=$(mktemp)
if ! jq \
	--arg cmd "$HOOK_CMD" \
	--arg managed_log "$MANAGED_LOG_CMD" \
	--arg managed_mode_log "$MANAGED_MODE_LOG_CMD" \
	--arg managed_auto "$MANAGED_AUTO_CMD" \
	--arg managed_mode_auto "$MANAGED_MODE_AUTO_CMD" \
	--arg managed_worktree "$MANAGED_WORKTREE_CMD" \
	--arg managed_mode_worktree "$MANAGED_MODE_WORKTREE_CMD" \
	--arg managed_new_mode_log "$MANAGED_NEW_MODE_LOG_CMD" \
	--arg managed_new_mode_auto "$MANAGED_NEW_MODE_AUTO_CMD" \
	--arg managed_new_mode_worktree "$MANAGED_NEW_MODE_WORKTREE_CMD" '
    .hooks //= {} |
    .hooks.PermissionRequest //= [] |
    .hooks.PermissionRequest = (
      [
        .hooks.PermissionRequest[]
        | .hooks = (
            (.hooks // [])
            | map(
                select(
                  (.command == $managed_log
                   or .command == $managed_mode_log
                   or .command == $managed_auto
                   or .command == $managed_mode_auto
                   or .command == $managed_worktree
                   or .command == $managed_mode_worktree
                   or .command == $managed_new_mode_log
                   or .command == $managed_new_mode_auto
                   or .command == $managed_new_mode_worktree)
                  | not
                )
              )
          )
        | select((.hooks | length) > 0)
      ] + [{
        matcher: "*",
        hooks: [{type: "command", command: $cmd}]
      }]
    )
  ' "$SETTINGS" >"$TEMP"; then
	echo "permissionsync-cc: ERROR: failed to update $SETTINGS" >&2
	rm -f "$TEMP"
	exit 1
fi

if ! cmp -s "$SETTINGS" "$TEMP"; then
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP" "$SETTINGS"
	changed=1
else
	rm -f "$TEMP"
fi

# 4. Wire PostToolUse hook for confirmed-approvals log (idempotent)
# Evicts old name (log-confirmed.sh) and current name before re-adding current.
CONFIRMED_CMD="$HOOKS_DIR/permissionsync-log-confirmed.sh"
CONFIRMED_CMD_OLD="$HOOKS_DIR/log-confirmed.sh"
TEMP2=$(mktemp)
if ! jq \
	--arg cmd "$CONFIRMED_CMD" \
	--arg old_cmd "$CONFIRMED_CMD_OLD" '
    .hooks //= {} |
    .hooks.PostToolUse //= [] |
    .hooks.PostToolUse = (
      [
        .hooks.PostToolUse[]
        | .hooks = ((.hooks // []) | map(select(.command != $cmd and .command != $old_cmd)))
        | select((.hooks | length) > 0)
      ] + [{
        matcher: "*",
        hooks: [{type: "command", command: $cmd}]
      }]
    )
  ' "$SETTINGS" >"$TEMP2"; then
	echo "permissionsync-cc: ERROR: failed to wire PostToolUse hook" >&2
	rm -f "$TEMP2"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP2"; then
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP2" "$SETTINGS"
	changed=1
else
	rm -f "$TEMP2"
fi

# 5. Wire PostToolUseFailure hook for hook-errors log (idempotent)
ERRORS_CMD="$HOOKS_DIR/permissionsync-log-hook-errors.sh"
TEMP3=$(mktemp)
if ! jq \
	--arg cmd "$ERRORS_CMD" '
    .hooks //= {} |
    .hooks.PostToolUseFailure //= [] |
    .hooks.PostToolUseFailure = (
      [
        .hooks.PostToolUseFailure[]
        | .hooks = ((.hooks // []) | map(select(.command != $cmd)))
        | select((.hooks | length) > 0)
      ] + [{
        matcher: "*",
        hooks: [{type: "command", command: $cmd}]
      }]
    )
  ' "$SETTINGS" >"$TEMP3"; then
	echo "permissionsync-cc: ERROR: failed to wire PostToolUseFailure hook" >&2
	rm -f "$TEMP3"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP3"; then
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP3" "$SETTINGS"
	changed=1
else
	rm -f "$TEMP3"
fi

# 6. Wire ConfigChange hook for config-changes log (idempotent)
WATCH_CMD="$HOOKS_DIR/permissionsync-watch-config.sh"
TEMP4=$(mktemp)
if ! jq \
	--arg cmd "$WATCH_CMD" '
    .hooks //= {} |
    .hooks.ConfigChange //= [] |
    .hooks.ConfigChange = (
      [
        .hooks.ConfigChange[]
        | .hooks = ((.hooks // []) | map(select(.command != $cmd)))
        | select((.hooks | length) > 0)
      ] + [{
        matcher: "user_settings",
        hooks: [{type: "command", command: $cmd}]
      }]
    )
  ' "$SETTINGS" >"$TEMP4"; then
	echo "permissionsync-cc: ERROR: failed to wire ConfigChange hook" >&2
	rm -f "$TEMP4"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP4"; then
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP4" "$SETTINGS"
	changed=1
else
	rm -f "$TEMP4"
fi

# 7. Wire SessionEnd hook for auto-sync (idempotent)
SYNCEND_CMD="$HOOKS_DIR/permissionsync-sync-on-end.sh"
TEMP5=$(mktemp)
if ! jq \
	--arg cmd "$SYNCEND_CMD" '
    .hooks //= {} |
    .hooks.SessionEnd //= [] |
    .hooks.SessionEnd = (
      [
        .hooks.SessionEnd[]
        | .hooks = ((.hooks // []) | map(select(.command != $cmd)))
        | select((.hooks | length) > 0)
      ] + [{
        matcher: "*",
        hooks: [{type: "command", command: $cmd}]
      }]
    )
  ' "$SETTINGS" >"$TEMP5"; then
	echo "permissionsync-cc: ERROR: failed to wire SessionEnd hook" >&2
	rm -f "$TEMP5"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP5"; then
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP5" "$SETTINGS"
	changed=1
else
	rm -f "$TEMP5"
fi

# 8. Wire SessionStart hook for drift notification (idempotent)
# Evicts old name (session-start.sh) and current name before re-adding current.
SESSION_START_CMD="$HOOKS_DIR/permissionsync-session-start.sh"
SESSION_START_CMD_OLD="$HOOKS_DIR/session-start.sh"
TEMP6=$(mktemp)
if ! jq \
	--arg cmd "$SESSION_START_CMD" \
	--arg old_cmd "$SESSION_START_CMD_OLD" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    .hooks.SessionStart = (
      [
        .hooks.SessionStart[]
        | .hooks = ((.hooks // []) | map(select(.command != $cmd and .command != $old_cmd)))
        | select((.hooks | length) > 0)
      ] + [{
        hooks: [{type: "command", command: $cmd}]
      }]
    )
  ' "$SETTINGS" >"$TEMP6"; then
	echo "permissionsync-cc: ERROR: failed to wire SessionStart hook" >&2
	rm -f "$TEMP6"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP6"; then
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP6" "$SETTINGS"
	changed=1
else
	rm -f "$TEMP6"
fi

# 9. Wire WorktreeCreate hook for settings seeding (idempotent)
# Evicts old name (worktree-create.sh) and current name before re-adding current.
WORKTREE_CREATE_CMD="$HOOKS_DIR/permissionsync-worktree-create.sh"
WORKTREE_CREATE_CMD_OLD="$HOOKS_DIR/worktree-create.sh"
TEMP7=$(mktemp)
if ! jq \
	--arg cmd "$WORKTREE_CREATE_CMD" \
	--arg old_cmd "$WORKTREE_CREATE_CMD_OLD" '
    .hooks //= {} |
    .hooks.WorktreeCreate //= [] |
    .hooks.WorktreeCreate = (
      [
        .hooks.WorktreeCreate[]
        | .hooks = ((.hooks // []) | map(select(.command != $cmd and .command != $old_cmd)))
        | select((.hooks | length) > 0)
      ] + [{
        hooks: [{type: "command", command: $cmd}]
      }]
    )
  ' "$SETTINGS" >"$TEMP7"; then
	echo "permissionsync-cc: ERROR: failed to wire WorktreeCreate hook" >&2
	rm -f "$TEMP7"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP7"; then
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP7" "$SETTINGS"
	changed=1
else
	rm -f "$TEMP7"
fi

# 10. Seed baseline permissions (idempotent — skips if allow rules already exist)
seed_baseline_permissions "$HOOKS_DIR" "$SETTINGS"

# Report only when something changed
if [[ $changed -eq 1 ]]; then
	echo "permissionsync-cc: hooks installed ($MODE mode)"
fi
