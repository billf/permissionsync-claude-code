#!/usr/bin/env bash
# install.sh — sets up the permission logger hook in ~/.claude/settings.json
#
# What it does:
#   1. Copies hook scripts to ~/.claude/hooks/
#   2. Adds a PermissionRequest hook to ~/.claude/settings.json (user-level)
#   3. Optionally enables auto-approve mode
#
# Usage:
#   ./install.sh              # log-only mode (default)
#   ./install.sh --auto       # also auto-approve previously-seen rules
#   ./install.sh --worktree   # auto-approve + sibling worktree rules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
MODE="${1:-}"

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
	# shellcheck source=permissionsync-lib.sh
	source "${hooks_dir}/permissionsync-lib.sh"

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
	echo "✓ Seeded $count baseline safe-subcommand rules into $settings"
}

# 1. Copy hook scripts (including shared library files)
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/permissionsync-config.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-lib.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/log-permission.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/log-permission-auto.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/log-confirmed.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/sync-permissions.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/worktree-sync.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/merged-settings.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/permissionsync-config.sh"
chmod +x "$HOOKS_DIR/permissionsync-lib.sh"
chmod +x "$HOOKS_DIR/log-permission.sh"
chmod +x "$HOOKS_DIR/log-permission-auto.sh"
chmod +x "$HOOKS_DIR/log-confirmed.sh"
chmod +x "$HOOKS_DIR/sync-permissions.sh"
chmod +x "$HOOKS_DIR/worktree-sync.sh"
chmod +x "$HOOKS_DIR/merged-settings.sh"
echo "✓ Copied scripts to $HOOKS_DIR/"

# 2. Choose which hook script to wire up
case "$MODE" in
--auto)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=auto $HOOKS_DIR/log-permission-auto.sh"
	echo "✓ Mode: auto-approve previously-seen rules"
	;;
--worktree)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=worktree $HOOKS_DIR/log-permission-auto.sh"
	echo "✓ Mode: auto-approve + sibling worktree rules"
	;;
*)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=log $HOOKS_DIR/log-permission-auto.sh"
	echo "✓ Mode: log-only (manual approval still required)"
	;;
esac
# Managed command patterns: all legacy and new-style variants that install.sh owns
MANAGED_LOG_CMD="$HOOKS_DIR/log-permission.sh"
MANAGED_MODE_LOG_CMD="CLAUDE_PERMISSION_MODE=log $HOOKS_DIR/log-permission-auto.sh"
MANAGED_AUTO_CMD="CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
MANAGED_MODE_AUTO_CMD="CLAUDE_PERMISSION_MODE=auto $HOOKS_DIR/log-permission-auto.sh"
MANAGED_WORKTREE_CMD="CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
MANAGED_MODE_WORKTREE_CMD="CLAUDE_PERMISSION_MODE=worktree $HOOKS_DIR/log-permission-auto.sh"

# 3. Merge hook config into settings.json
if [[ ! -f $SETTINGS ]]; then
	echo '{}' >"$SETTINGS"
fi

TEMP=$(mktemp)
if ! jq \
	--arg cmd "$HOOK_CMD" \
	--arg managed_log "$MANAGED_LOG_CMD" \
	--arg managed_mode_log "$MANAGED_MODE_LOG_CMD" \
	--arg managed_auto "$MANAGED_AUTO_CMD" \
	--arg managed_mode_auto "$MANAGED_MODE_AUTO_CMD" \
	--arg managed_worktree "$MANAGED_WORKTREE_CMD" \
	--arg managed_mode_worktree "$MANAGED_MODE_WORKTREE_CMD" '
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
                   or .command == $managed_mode_worktree)
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
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP" "$SETTINGS"
	echo "✓ Updated PermissionRequest hook in $SETTINGS"
else
	rm -f "$TEMP"
	echo "✓ Hook already installed in $SETTINGS"
fi

# 4. Wire PostToolUse hook for confirmed-approvals log
CONFIRMED_CMD="$HOOKS_DIR/log-confirmed.sh"
TEMP2=$(mktemp)
if ! jq \
	--arg cmd "$CONFIRMED_CMD" '
    .hooks //= {} |
    .hooks.PostToolUse //= [] |
    .hooks.PostToolUse = (
      [
        .hooks.PostToolUse[]
        | .hooks = ((.hooks // []) | map(select(.command != $cmd)))
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
	cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
	mv "$TEMP2" "$SETTINGS"
	echo "✓ Wired PostToolUse hook (confirmed-approvals log)"
else
	rm -f "$TEMP2"
fi

# 5. Seed baseline permissions (skips if settings already has allow rules)
seed_baseline_permissions "$HOOKS_DIR" "$SETTINGS"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "How it works:"
echo "  Every permission prompt in Claude Code now logs to:"
echo "    ~/.claude/permission-approvals.jsonl"
echo ""
echo "  To sync logged approvals into your global settings:"
echo "    ~/.claude/hooks/sync-permissions.sh --preview   # see what would change"
echo "    ~/.claude/hooks/sync-permissions.sh --apply     # write to settings.json"
echo ""
echo "  To add sync as a shell alias:"
echo '    alias claude-sync-perms="~/.claude/hooks/sync-permissions.sh"'
echo ""
echo "  To launch a worktree with merged permissions:"
echo '    claude -w feature-x --settings <(~/.claude/hooks/merged-settings.sh --refine)'
echo ""
if [[ $MODE != "--auto" ]] && [[ $MODE != "--worktree" ]]; then
	echo "  To enable auto-approve mode later:"
	echo "    $0 --auto"
	echo ""
	echo "  To enable worktree-aware auto-approve:"
	echo "    $0 --worktree"
fi
