#!/usr/bin/env bash
# permissionsync.sh — unified CLI dispatcher for permissionsync-cc
#
# Usage:
#   permissionsync.sh <subcommand> [args...]
#
# Subcommands:
#   sync     [--apply] [--refine] [--diff] [--print] [--from-confirmed]
#            Sync JSONL approval log rules into ~/.claude/settings.json
#
#   worktree [--apply] [--apply-all] [--report] [--diff] [--refine] [--from-log]
#            Aggregate and sync rules across git worktrees
#
#   settings [--refine] [--from-log] [--global-only]
#            Output merged permissions JSON for claude --settings
#
#   launch   [--from-log] [--global-only] [--no-refine] [--dry-run] <name> [-- CLAUDE_ARGS...]
#            Launch claude in a new worktree with merged permission settings
#
#   install  [--mode=log|auto|worktree]
#            Install hooks and configure ~/.claude/settings.json
#
#   status   Show current permissionsync state (hooks, rules, log)
#
# Each subcommand delegates to the corresponding script in the same directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
	cat >&2 <<'USAGE'
Usage: permissionsync.sh <subcommand> [args...]

Subcommands:
  sync      Sync approval log rules into ~/.claude/settings.json
  worktree  Aggregate and sync rules across git worktrees
  settings  Output merged permissions JSON for claude --settings
  launch    Launch claude in a new worktree with merged permissions
  install   Install hooks and configure ~/.claude/settings.json
  status    Show current permissionsync state

Run 'permissionsync.sh <subcommand> --help' for subcommand usage.
USAGE
}

# --- status subcommand (implemented here; doesn't delegate) ---
cmd_status() {
	local settings="$HOME/.claude/settings.json"
	local log_file="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
	local confirmed_log
	confirmed_log="$(dirname "$log_file")/confirmed-approvals.jsonl"

	echo "=== permissionsync-cc status ==="
	echo ""

	# Hook installation
	echo "Hooks:"
	local hook_installed=0
	if [[ -f $settings ]]; then
		if jq -e '.hooks.PermissionRequest[]?.hooks[]? | select(.command != null and (.command | contains("log-permission")))' \
			"$settings" >/dev/null 2>&1; then
			local mode old_cmd
			mode=$(jq -r '.hooks.PermissionRequest[]?.hooks[]?.command // empty' "$settings" 2>/dev/null |
				grep -o 'CLAUDE_PERMISSION_MODE=[a-z]*' | head -1 | cut -d= -f2 || true)
			if [[ -z $mode ]]; then
				# Detect old-style env vars (pre-CLAUDE_PERMISSION_MODE installs)
				old_cmd=$(jq -r '.hooks.PermissionRequest[]?.hooks[]?.command // empty' "$settings" 2>/dev/null |
					grep 'log-permission' | head -1 || true)
				if echo "$old_cmd" | grep -q 'CLAUDE_PERMISSION_WORKTREE'; then
					mode="worktree (legacy — re-run installer to upgrade)"
				elif echo "$old_cmd" | grep -q 'CLAUDE_PERMISSION_AUTO'; then
					mode="auto (legacy — re-run installer to upgrade)"
				else
					mode="log (legacy — re-run installer to upgrade)"
				fi
			fi
			echo "  PermissionRequest: installed (mode: $mode)"
			hook_installed=1
		fi
	fi
	if [[ $hook_installed -eq 0 ]]; then
		echo "  PermissionRequest: NOT installed"
	fi

	local posttooluse_installed=0
	if [[ -f $settings ]]; then
		if jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command != null and (.command | contains("log-confirmed")))' \
			"$settings" >/dev/null 2>&1; then
			echo "  PostToolUse: installed (confirmed-approvals log)"
			posttooluse_installed=1
		fi
	fi
	if [[ $posttooluse_installed -eq 0 ]]; then
		echo "  PostToolUse: NOT installed"
	fi
	echo ""

	# Settings
	echo "Settings ($settings):"
	if [[ -f $settings ]]; then
		local allow_count deny_count
		allow_count=$(jq '[.permissions.allow[]?] | length' "$settings" 2>/dev/null || echo 0)
		deny_count=$(jq '[.permissions.deny[]?] | length' "$settings" 2>/dev/null || echo 0)
		echo "  Allow rules: $allow_count"
		echo "  Deny rules:  $deny_count"
	else
		echo "  (file not found)"
	fi
	echo ""

	# Approval log
	echo "Approval log ($log_file):"
	if [[ -f $log_file ]]; then
		local log_lines
		log_lines=$(wc -l <"$log_file" | tr -d ' ')
		echo "  Entries: $log_lines"
	else
		echo "  (not found — run Claude Code with the hook installed)"
	fi
	echo ""

	# Confirmed log
	echo "Confirmed log ($confirmed_log):"
	if [[ -f $confirmed_log ]]; then
		local confirmed_lines
		confirmed_lines=$(wc -l <"$confirmed_log" | tr -d ' ')
		echo "  Entries: $confirmed_lines"
	else
		echo "  (not found — PostToolUse hook must be installed)"
	fi
	echo ""

	# Git worktree context
	if git rev-parse --git-dir >/dev/null 2>&1; then
		local wt_count
		wt_count=$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || echo 1)
		echo "Git worktrees: $wt_count"
	fi
}

# --- Dispatch ---
if [[ $# -eq 0 ]]; then
	usage
	exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
sync)
	exec "${SCRIPT_DIR}/permissionsync-sync.sh" "$@"
	;;
worktree)
	exec "${SCRIPT_DIR}/permissionsync-worktree-sync.sh" "$@"
	;;
settings)
	exec "${SCRIPT_DIR}/permissionsync-settings.sh" "$@"
	;;
launch)
	exec "${SCRIPT_DIR}/permissionsync-launch.sh" "$@"
	;;
install)
	# Translate --mode=<value> to positional arg for permissionsync-install.sh
	MODE_ARG=""
	for arg in "$@"; do
		case "$arg" in
		--mode=log) MODE_ARG="" ;;
		--mode=auto) MODE_ARG="--auto" ;;
		--mode=worktree) MODE_ARG="--worktree" ;;
		--help | -h)
			echo "Usage: permissionsync.sh install [--mode=log|auto|worktree]" >&2
			exit 0
			;;
		*)
			echo "Unknown install option: $arg" >&2
			echo "Usage: permissionsync.sh install [--mode=log|auto|worktree]" >&2
			exit 1
			;;
		esac
	done
	if [[ -n $MODE_ARG ]]; then
		exec "${SCRIPT_DIR}/permissionsync-install.sh" "$MODE_ARG"
	else
		exec "${SCRIPT_DIR}/permissionsync-install.sh"
	fi
	;;
status)
	cmd_status
	;;
--help | -h | help)
	usage
	exit 0
	;;
*)
	echo "Unknown subcommand: $SUBCOMMAND" >&2
	usage
	exit 1
	;;
esac
