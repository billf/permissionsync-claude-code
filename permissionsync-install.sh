#!/usr/bin/env bash
# permissionsync-install.sh — sets up the permission logger hook in ~/.claude/settings.json
#
# What it does:
#   1. Copies hook scripts to ~/.claude/hooks/
#   2. Adds a PermissionRequest hook to ~/.claude/settings.json (user-level)
#   3. Optionally enables auto-approve mode
#
# Usage:
#   ./permissionsync-install.sh              # log-only mode (default)
#   ./permissionsync-install.sh --auto       # also auto-approve previously-seen rules
#   ./permissionsync-install.sh --worktree   # auto-approve + sibling worktree rules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
MODE="${1:-}"

# Temp file accumulator — cleaned up on any exit (normal, error, or signal).
_TEMPS=()
cleanup() { rm -f "${_TEMPS[@]}"; }
trap cleanup EXIT

echo "=== Claude Permission Logger — Installer ==="
echo ""

# seed_baseline_permissions HOOKS_DIR SETTINGS
#
# Pre-seeds ~/.claude/settings.json with all curated safe-subcommand rules
# from permissionsync-config.sh. This ensures the first session starts with
# known-safe operations already allowed, reducing prompt noise from day one.
# Only runs when settings.json has no existing permissions.allow rules.
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
	# shellcheck disable=SC2064
	trap "rm -f '$tmp'" RETURN
	jq --argjson rules "$rules_json" \
		'.permissions //= {} | .permissions.allow //= [] | .permissions.allow += $rules | .permissions.allow |= unique | .permissions.allow |= sort' \
		"$settings" >"$tmp" && mv "$tmp" "$settings"

	local count
	count=$(echo "$rules_json" | jq 'length')
	echo "✓ Seeded $count baseline safe-subcommand rules into $settings"
}

# 1. Copy hook scripts and shared libraries
mkdir -p "$HOOKS_DIR" "$HOOKS_DIR/lib"
cp "$SCRIPT_DIR/lib/permissionsync-lib.sh" "$HOOKS_DIR/lib/"
cp "$SCRIPT_DIR/lib/permissionsync-config.sh" "$HOOKS_DIR/lib/"
# log-permission-v1.sh (formerly log-permission.sh) not copied — eviction-list only
cp "$SCRIPT_DIR/permissionsync-log-permission.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-log-confirmed.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-sync.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-worktree-sync.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-settings.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-launch.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-log-hook-errors.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-watch-config.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-sync-on-end.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-session-start.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-worktree-create.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/permissionsync-log-permission.sh"
chmod +x "$HOOKS_DIR/permissionsync-log-confirmed.sh"
chmod +x "$HOOKS_DIR/permissionsync-sync.sh"
chmod +x "$HOOKS_DIR/permissionsync-worktree-sync.sh"
chmod +x "$HOOKS_DIR/permissionsync-settings.sh"
chmod +x "$HOOKS_DIR/permissionsync-launch.sh"
chmod +x "$HOOKS_DIR/permissionsync.sh"
chmod +x "$HOOKS_DIR/permissionsync-log-hook-errors.sh"
chmod +x "$HOOKS_DIR/permissionsync-watch-config.sh"
chmod +x "$HOOKS_DIR/permissionsync-sync-on-end.sh"
chmod +x "$HOOKS_DIR/permissionsync-session-start.sh"
chmod +x "$HOOKS_DIR/permissionsync-worktree-create.sh"
echo "✓ Copied scripts to $HOOKS_DIR/"

# 2. Choose which hook script to wire up
case "$MODE" in
--auto)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=auto $HOOKS_DIR/permissionsync-log-permission.sh"
	echo "✓ Mode: auto-approve previously-seen rules"
	;;
--worktree)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=worktree $HOOKS_DIR/permissionsync-log-permission.sh"
	echo "✓ Mode: auto-approve + sibling worktree rules"
	;;
*)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=log $HOOKS_DIR/permissionsync-log-permission.sh"
	echo "✓ Mode: log-only (manual approval still required)"
	;;
esac
# Managed command patterns: all legacy and current variants that this installer owns.
# Listed here so any previously-installed variant is evicted on re-install.
# Old script name (log-permission.sh):
MANAGED_LOG_CMD="$HOOKS_DIR/log-permission.sh"
# v1 legacy script — not installed by either installer; eviction-list only.
# Handles the edge case where a user manually wired it before it was deprecated.
MANAGED_V1_CMD="$HOOKS_DIR/permissionsync-log-permission-v1.sh"
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

# 3. Merge hook config into settings.json
if [[ ! -f $SETTINGS ]]; then
	echo '{}' >"$SETTINGS"
fi

# Take one backup of the original settings before any modification.
# Only created when the file exists and no backup has been taken yet.
if [[ ! -f "${SETTINGS}.bak" ]]; then
	cp "$SETTINGS" "${SETTINGS}.bak"
	echo "permissionsync: backed up settings.json to ${SETTINGS}.bak"
else
	echo "permissionsync: ${SETTINGS}.bak already exists — skipping backup"
fi

TEMP=$(mktemp)
_TEMPS+=("$TEMP")
if ! jq \
	--arg cmd "$HOOK_CMD" \
	--arg managed_log "$MANAGED_LOG_CMD" \
	--arg managed_v1 "$MANAGED_V1_CMD" \
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
                   or .command == $managed_v1
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
	echo "ERROR: Failed to update $SETTINGS"
	rm -f "$TEMP"
	exit 1
fi

if ! cmp -s "$SETTINGS" "$TEMP"; then
	mv "$TEMP" "$SETTINGS"
	echo "✓ Updated PermissionRequest hook in $SETTINGS"
else
	rm -f "$TEMP"
	echo "✓ Hook already installed in $SETTINGS"
fi

# 4. Wire PostToolUse hook for confirmed-approvals log
# Evicts old name (log-confirmed.sh) and current name before re-adding current.
CONFIRMED_CMD="$HOOKS_DIR/permissionsync-log-confirmed.sh"
CONFIRMED_CMD_OLD="$HOOKS_DIR/log-confirmed.sh"
TEMP2=$(mktemp)
_TEMPS+=("$TEMP2")
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
	echo "ERROR: Failed to wire PostToolUse hook in $SETTINGS"
	rm -f "$TEMP2"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP2"; then
	mv "$TEMP2" "$SETTINGS"
	echo "✓ Wired PostToolUse hook (confirmed-approvals log)"
else
	rm -f "$TEMP2"
fi

# 5. Wire PostToolUseFailure hook for hook-errors log
ERRORS_CMD="$HOOKS_DIR/permissionsync-log-hook-errors.sh"
TEMP3=$(mktemp)
_TEMPS+=("$TEMP3")
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
	echo "ERROR: Failed to wire PostToolUseFailure hook in $SETTINGS"
	rm -f "$TEMP3"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP3"; then
	mv "$TEMP3" "$SETTINGS"
	echo "✓ Wired PostToolUseFailure hook (hook-errors log)"
else
	rm -f "$TEMP3"
fi

# 6. Wire ConfigChange hook for config-changes log
WATCH_CMD="$HOOKS_DIR/permissionsync-watch-config.sh"
TEMP4=$(mktemp)
_TEMPS+=("$TEMP4")
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
	echo "ERROR: Failed to wire ConfigChange hook in $SETTINGS"
	rm -f "$TEMP4"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP4"; then
	mv "$TEMP4" "$SETTINGS"
	echo "✓ Wired ConfigChange hook (config-changes log)"
else
	rm -f "$TEMP4"
fi

# 7. Wire SessionEnd hook for auto-sync
SYNCEND_CMD="$HOOKS_DIR/permissionsync-sync-on-end.sh"
TEMP5=$(mktemp)
_TEMPS+=("$TEMP5")
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
	echo "ERROR: Failed to wire SessionEnd hook in $SETTINGS"
	rm -f "$TEMP5"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP5"; then
	mv "$TEMP5" "$SETTINGS"
	echo "✓ Wired SessionEnd hook (auto-sync on exit)"
else
	rm -f "$TEMP5"
fi

# 8. Wire SessionStart hook for drift notification
# Evicts old name (session-start.sh) and current name before re-adding current.
SESSION_START_CMD="$HOOKS_DIR/permissionsync-session-start.sh"
SESSION_START_CMD_OLD="$HOOKS_DIR/session-start.sh"
TEMP6=$(mktemp)
_TEMPS+=("$TEMP6")
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
	echo "ERROR: Failed to wire SessionStart hook in $SETTINGS"
	rm -f "$TEMP6"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP6"; then
	mv "$TEMP6" "$SETTINGS"
	echo "✓ Wired SessionStart hook (drift notification)"
else
	rm -f "$TEMP6"
fi

# 9. Wire WorktreeCreate hook for settings seeding
# Evicts old name (worktree-create.sh) and current name before re-adding current.
WORKTREE_CREATE_CMD="$HOOKS_DIR/permissionsync-worktree-create.sh"
WORKTREE_CREATE_CMD_OLD="$HOOKS_DIR/worktree-create.sh"
TEMP7=$(mktemp)
_TEMPS+=("$TEMP7")
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
	echo "ERROR: Failed to wire WorktreeCreate hook in $SETTINGS"
	rm -f "$TEMP7"
	exit 1
fi
if ! cmp -s "$SETTINGS" "$TEMP7"; then
	mv "$TEMP7" "$SETTINGS"
	echo "✓ Wired WorktreeCreate hook (settings seeding)"
else
	rm -f "$TEMP7"
fi

# 10. Seed baseline permissions (skips if settings already has allow rules)
seed_baseline_permissions "$HOOKS_DIR" "$SETTINGS"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "How it works:"
echo "  Every permission prompt in Claude Code now logs to:"
echo "    ~/.claude/permission-approvals.jsonl"
echo ""
echo "  To sync logged approvals into your global settings:"
echo "    ~/.claude/hooks/permissionsync-sync.sh --preview   # see what would change"
echo "    ~/.claude/hooks/permissionsync-sync.sh --apply     # write to settings.json"
echo ""
echo "  To add sync as a shell alias:"
echo '    alias claude-sync-perms="~/.claude/hooks/permissionsync-sync.sh"'
echo ""
echo "  To launch a worktree with merged permissions:"
echo '    claude -w feature-x --settings <(~/.claude/hooks/permissionsync-settings.sh --refine)'
echo ""
if [[ $MODE != "--auto" ]] && [[ $MODE != "--worktree" ]]; then
	echo "  To enable auto-approve mode later:"
	echo "    $0 --auto"
	echo ""
	echo "  To enable worktree-aware auto-approve:"
	echo "    $0 --worktree"
fi
