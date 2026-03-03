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

# shellcheck source=lib/permissionsync-install-lib.sh
source "$SCRIPT_DIR/lib/permissionsync-install-lib.sh"

echo "=== Claude Permission Logger — Installer ==="
echo ""

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

# 3. Ensure settings.json exists
if [[ ! -f $SETTINGS ]]; then
	echo '{}' >"$SETTINGS"
fi

# 4. Wire all hooks (each call evicts legacy names then adds current)
if wire_hook "PermissionRequest" "$HOOK_CMD" "*" "permission logger" \
	"$MANAGED_LOG_CMD" "$MANAGED_MODE_LOG_CMD" \
	"$MANAGED_AUTO_CMD" "$MANAGED_MODE_AUTO_CMD" \
	"$MANAGED_WORKTREE_CMD" "$MANAGED_MODE_WORKTREE_CMD" \
	"$MANAGED_NEW_MODE_LOG_CMD" "$MANAGED_NEW_MODE_AUTO_CMD" \
	"$MANAGED_NEW_MODE_WORKTREE_CMD"; then
	echo "✓ Updated PermissionRequest hook in $SETTINGS"
else
	echo "✓ Hook already installed in $SETTINGS"
fi
wire_hook "PostToolUse" "$HOOKS_DIR/permissionsync-log-confirmed.sh" "*" "confirmed-approvals log" \
	"$HOOKS_DIR/log-confirmed.sh" &&
	echo "✓ Wired PostToolUse hook (confirmed-approvals log)"
wire_hook "PostToolUseFailure" "$HOOKS_DIR/permissionsync-log-hook-errors.sh" "*" "hook-errors log" &&
	echo "✓ Wired PostToolUseFailure hook (hook-errors log)"
wire_hook "ConfigChange" "$HOOKS_DIR/permissionsync-watch-config.sh" "user_settings" "config-changes log" &&
	echo "✓ Wired ConfigChange hook (config-changes log)"
wire_hook "SessionEnd" "$HOOKS_DIR/permissionsync-sync-on-end.sh" "*" "auto-sync on exit" &&
	echo "✓ Wired SessionEnd hook (auto-sync on exit)"
wire_hook "SessionStart" "$HOOKS_DIR/permissionsync-session-start.sh" "" "drift notification" \
	"$HOOKS_DIR/session-start.sh" "$HOOKS_DIR/sync-permissions.sh --diff" &&
	echo "✓ Wired SessionStart hook (drift notification)"
wire_hook "WorktreeCreate" "$HOOKS_DIR/permissionsync-worktree-create.sh" "" "settings seeding" \
	"$HOOKS_DIR/worktree-create.sh" &&
	echo "✓ Wired WorktreeCreate hook (settings seeding)"

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
