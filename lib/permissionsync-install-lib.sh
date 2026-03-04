#!/usr/bin/env bash
# permissionsync-install-lib.sh — shared functions for both installers
#
# Sourced by permissionsync-setup.sh and permissionsync-install.sh.
# Requires SETTINGS to be set by the caller.
# PERMISSIONSYNC_LIB_DIR is optional — falls back to this file's directory.

_PERMISSIONSYNC_INSTALL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# wire_hook EVENT CMD MATCHER LABEL [OLD_CMD...]
#
# Idempotently wires a hook command into settings.json under .hooks[EVENT].
# Removes CMD and any OLD_CMDs first, then appends a fresh entry.
#
# Parameters:
#   EVENT   — hook event name (e.g. "PostToolUse", "SessionStart")
#   CMD     — the command string to wire
#   MATCHER — matcher value ("*", "user_settings") or "" for no matcher field
#   LABEL   — human-readable label for error messages
#   OLD_CMD — zero or more legacy command strings to evict
#
# Returns 0 if settings changed, 1 if no-op.
# Exits with code 1 on jq failure.
# shellcheck disable=SC2153  # SETTINGS is set by the caller
wire_hook() {
	local event="$1" cmd="$2" matcher="$3"
	shift 4 # skip label (used by callers for their own messaging)
	local evict_json
	evict_json=$(printf '%s\n' "$cmd" "$@" | jq -R -s 'split("\n") | map(select(length > 0))')

	local tmp
	tmp=$(mktemp)
	if ! jq -L "${PERMISSIONSYNC_LIB_DIR:-$_PERMISSIONSYNC_INSTALL_LIB_DIR}" \
		--arg event "$event" \
		--arg cmd "$cmd" \
		--arg matcher "$matcher" \
		--argjson evict "$evict_json" \
		'include "wire-hook"; wire_hook($event; $cmd; $matcher; $evict)' \
		"$SETTINGS" >"$tmp"; then
		echo "ERROR: Failed to wire ${event} hook in $SETTINGS" >&2
		rm -f "$tmp"
		exit 1
	fi
	if ! cmp -s "$SETTINGS" "$tmp"; then
		if [[ ! -f "${SETTINGS}.bak" ]]; then
			cp "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
		fi
		mv "$tmp" "$SETTINGS"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

# resolve_hook_cmd MODE HOOKS_DIR
#
# Sets HOOK_CMD based on the permission mode. Normalizes mode format
# (strips leading dashes) so both installers can pass their native format.
# shellcheck disable=SC2034  # HOOK_CMD is used by callers
resolve_hook_cmd() {
	local mode="${1#--}" hooks_dir="$2"
	case "$mode" in
	auto)
		HOOK_CMD="CLAUDE_PERMISSION_MODE=auto $hooks_dir/permissionsync-log-permission.sh"
		;;
	worktree)
		HOOK_CMD="CLAUDE_PERMISSION_MODE=worktree $hooks_dir/permissionsync-log-permission.sh"
		;;
	*)
		HOOK_CMD="CLAUDE_PERMISSION_MODE=log $hooks_dir/permissionsync-log-permission.sh"
		;;
	esac
}

# set_managed_cmds HOOKS_DIR
#
# Sets all MANAGED_*_CMD variables for legacy command eviction.
# Both installers call this to build the eviction list for wire_hook.
# shellcheck disable=SC2034  # MANAGED_*_CMD vars are used by callers
set_managed_cmds() {
	local hooks_dir="$1"
	# Old script name (log-permission.sh):
	MANAGED_LOG_CMD="$hooks_dir/log-permission.sh"
	# v1 legacy script — not installed by either installer; eviction-list only.
	MANAGED_V1_CMD="$hooks_dir/permissionsync-log-permission-v1.sh"
	# Old script name (log-permission-auto.sh):
	MANAGED_MODE_LOG_CMD="CLAUDE_PERMISSION_MODE=log $hooks_dir/log-permission-auto.sh"
	MANAGED_AUTO_CMD="CLAUDE_PERMISSION_AUTO=1 $hooks_dir/log-permission-auto.sh"
	MANAGED_MODE_AUTO_CMD="CLAUDE_PERMISSION_MODE=auto $hooks_dir/log-permission-auto.sh"
	MANAGED_WORKTREE_CMD="CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 $hooks_dir/log-permission-auto.sh"
	MANAGED_WORKTREE_CMD_ALT="CLAUDE_PERMISSION_AUTO=1 CLAUDE_PERMISSION_WORKTREE=1 $hooks_dir/log-permission-auto.sh"
	MANAGED_MODE_WORKTREE_CMD="CLAUDE_PERMISSION_MODE=worktree $hooks_dir/log-permission-auto.sh"
	# Current script name (permissionsync-log-permission.sh):
	MANAGED_NEW_MODE_LOG_CMD="CLAUDE_PERMISSION_MODE=log $hooks_dir/permissionsync-log-permission.sh"
	MANAGED_NEW_MODE_AUTO_CMD="CLAUDE_PERMISSION_MODE=auto $hooks_dir/permissionsync-log-permission.sh"
	MANAGED_NEW_MODE_WORKTREE_CMD="CLAUDE_PERMISSION_MODE=worktree $hooks_dir/permissionsync-log-permission.sh"
}

# seed_baseline_permissions HOOKS_DIR SETTINGS
#
# Pre-seeds settings.json with curated safe-subcommand rules from config.
# Idempotent: skips if permissions.allow already has any entries.
seed_baseline_permissions() {
	local hooks_dir="$1" settings="$2"
	# shellcheck source=permissionsync-lib.sh
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
	if ! jq --argjson rules "$rules_json" \
		'.permissions //= {} | .permissions.allow //= [] | .permissions.allow += $rules | .permissions.allow |= unique | .permissions.allow |= sort' \
		"$settings" >"$tmp"; then
		rm -f "$tmp"
		echo "ERROR: Failed to seed baseline permissions in $settings" >&2
		return 1
	fi
	mv "$tmp" "$settings"

	local count
	count=$(jq 'length' <<<"$rules_json")
	echo "permissionsync-cc: seeded $count baseline rules into $settings"
}
