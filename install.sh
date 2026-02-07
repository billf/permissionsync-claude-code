#!/usr/bin/env bash
# install.sh — sets up the permission logger hook in ~/.claude/settings.json
#
# What it does:
#   1. Copies hook scripts to ~/.claude/hooks/
#   2. Adds a PermissionRequest hook to ~/.claude/settings.json (user-level)
#   3. Optionally enables auto-approve mode
#
# Usage:
#   ./install.sh           # log-only mode (default)
#   ./install.sh --auto    # also auto-approve previously-seen rules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
MODE="${1:-}"

echo "=== Claude Permission Logger — Installer ==="
echo ""

# 1. Copy hook scripts (including shared library files)
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/permissionsync-config.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-lib.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/log-permission.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/log-permission-auto.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/sync-permissions.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/permissionsync-config.sh"
chmod +x "$HOOKS_DIR/permissionsync-lib.sh"
chmod +x "$HOOKS_DIR/log-permission.sh"
chmod +x "$HOOKS_DIR/log-permission-auto.sh"
chmod +x "$HOOKS_DIR/sync-permissions.sh"
echo "✓ Copied scripts to $HOOKS_DIR/"

# 2. Choose which hook script to wire up
if [[ $MODE == "--auto" ]]; then
	HOOK_CMD="CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
	echo "✓ Mode: auto-approve previously-seen rules"
else
	HOOK_CMD="$HOOKS_DIR/log-permission.sh"
	echo "✓ Mode: log-only (manual approval still required)"
fi

# 3. Merge hook config into settings.json
if [[ ! -f $SETTINGS ]]; then
	echo '{}' >"$SETTINGS"
fi

# Check if PermissionRequest hook already exists
EXISTING=$(jq '.hooks.PermissionRequest // []' "$SETTINGS" 2>/dev/null || echo '[]')
ALREADY_INSTALLED=$(echo "$EXISTING" | jq --arg cmd "$HOOK_CMD" '[.[] | .hooks[]? | select(.command == $cmd)] | length')

if [[ $ALREADY_INSTALLED -gt 0 ]]; then
	echo "✓ Hook already installed in $SETTINGS"
else
	# Build the new hook entry
	HOOK_ENTRY=$(jq -nc --arg cmd "$HOOK_CMD" '{
    "matcher": "*",
    "hooks": [{"type": "command", "command": $cmd}]
  }')

	TEMP=$(mktemp)
	jq --argjson entry "$HOOK_ENTRY" '
    .hooks //= {} |
    .hooks.PermissionRequest //= [] |
    .hooks.PermissionRequest += [$entry]
  ' "$SETTINGS" >"$TEMP"

	if jq empty "$TEMP" 2>/dev/null; then
		cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
		mv "$TEMP" "$SETTINGS"
		echo "✓ Added PermissionRequest hook to $SETTINGS"
	else
		echo "ERROR: Failed to update $SETTINGS"
		rm -f "$TEMP"
		exit 1
	fi
fi

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
if [[ $MODE != "--auto" ]]; then
	echo "  To enable auto-approve mode later:"
	echo "    $0 --auto"
fi
