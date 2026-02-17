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

# 1. Copy hook scripts (including shared library files)
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/permissionsync-config.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/permissionsync-lib.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/log-permission.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/log-permission-auto.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/sync-permissions.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/worktree-sync.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/permissionsync-config.sh"
chmod +x "$HOOKS_DIR/permissionsync-lib.sh"
chmod +x "$HOOKS_DIR/log-permission.sh"
chmod +x "$HOOKS_DIR/log-permission-auto.sh"
chmod +x "$HOOKS_DIR/sync-permissions.sh"
chmod +x "$HOOKS_DIR/worktree-sync.sh"
echo "✓ Copied scripts to $HOOKS_DIR/"

# 2. Choose which hook script to wire up
case "$MODE" in
--auto)
	HOOK_CMD="CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
	echo "✓ Mode: auto-approve previously-seen rules"
	;;
--worktree)
	HOOK_CMD="CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
	echo "✓ Mode: auto-approve + sibling worktree rules"
	;;
*)
	HOOK_CMD="$HOOKS_DIR/log-permission.sh"
	echo "✓ Mode: log-only (manual approval still required)"
	;;
esac
MANAGED_LOG_CMD="$HOOKS_DIR/log-permission.sh"
MANAGED_AUTO_CMD="CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
MANAGED_WORKTREE_CMD="CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"

# 3. Merge hook config into settings.json
if [[ ! -f $SETTINGS ]]; then
	echo '{}' >"$SETTINGS"
fi

TEMP=$(mktemp)
if ! jq \
	--arg cmd "$HOOK_CMD" \
	--arg managed_log "$MANAGED_LOG_CMD" \
	--arg managed_auto "$MANAGED_AUTO_CMD" \
	--arg managed_worktree "$MANAGED_WORKTREE_CMD" '
    .hooks //= {} |
    .hooks.PermissionRequest //= [] |
    .hooks.PermissionRequest = (
      [
        .hooks.PermissionRequest[]
        | .hooks = (
            (.hooks // [])
            | map(
                select(
                  (.command == $managed_log or .command == $managed_auto or .command == $managed_worktree)
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
if [[ $MODE != "--auto" ]] && [[ $MODE != "--worktree" ]]; then
	echo "  To enable auto-approve mode later:"
	echo "    $0 --auto"
	echo ""
	echo "  To enable worktree-aware auto-approve:"
	echo "    $0 --worktree"
fi
