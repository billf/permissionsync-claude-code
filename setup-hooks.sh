#!/usr/bin/env bash
# setup-hooks.sh — idempotent hook installer for use in Nix flake shellHooks
#
# Copies permissionsync-cc scripts to ~/.claude/hooks/ and ensures the
# PermissionRequest hook is configured in ~/.claude/settings.json.
#
# Designed to run on every shell entry: uses cmp(1) to skip unchanged files,
# checks settings.json before modifying, and produces no output when nothing
# changes.
#
# Usage:
#   setup-hooks.sh              # log-only mode (default)
#   setup-hooks.sh auto         # auto-approve previously-seen rules
#   setup-hooks.sh worktree     # auto-approve + sibling worktree rules
#
# When called from a Nix flake shellHook:
#   ${psc}/bin/setup-hooks.sh            # log mode
#   ${psc}/bin/setup-hooks.sh auto       # auto mode
#   ${psc}/bin/setup-hooks.sh worktree   # worktree mode

set -euo pipefail

# PERMISSIONSYNC_SHARE_DIR is patched by Nix to point to $out/share/permissionsync-cc
PERMISSIONSYNC_SHARE_DIR="${PERMISSIONSYNC_SHARE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
MODE="${1:-log}"

# seed_baseline_permissions HOOKS_DIR SETTINGS
#
# Pre-seeds settings.json with curated safe-subcommand rules from config.
# Idempotent: skips if permissions.allow already has any entries.
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
	echo "permissionsync-cc: seeded $count baseline rules into settings.json"
}

SCRIPTS=(
	permissionsync-config.sh
	permissionsync-lib.sh
	log-permission.sh
	log-permission-auto.sh
	log-confirmed.sh
	sync-permissions.sh
	worktree-sync.sh
	merged-settings.sh
)

changed=0

# 1. Copy hook scripts (only when changed)
mkdir -p "$HOOKS_DIR"
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
	HOOK_CMD="CLAUDE_PERMISSION_MODE=auto $HOOKS_DIR/log-permission-auto.sh"
	;;
worktree)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=worktree $HOOKS_DIR/log-permission-auto.sh"
	;;
*)
	HOOK_CMD="CLAUDE_PERMISSION_MODE=log $HOOKS_DIR/log-permission-auto.sh"
	;;
esac
# All managed command patterns (legacy and new-style) — used to identify and
# replace previously-installed managed hook entries.
MANAGED_LOG_CMD="$HOOKS_DIR/log-permission.sh"
MANAGED_MODE_LOG_CMD="CLAUDE_PERMISSION_MODE=log $HOOKS_DIR/log-permission-auto.sh"
MANAGED_AUTO_CMD="CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
MANAGED_MODE_AUTO_CMD="CLAUDE_PERMISSION_MODE=auto $HOOKS_DIR/log-permission-auto.sh"
MANAGED_WORKTREE_CMD="CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 $HOOKS_DIR/log-permission-auto.sh"
MANAGED_MODE_WORKTREE_CMD="CLAUDE_PERMISSION_MODE=worktree $HOOKS_DIR/log-permission-auto.sh"

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

# 5. Seed baseline permissions (idempotent — skips if allow rules already exist)
seed_baseline_permissions "$HOOKS_DIR" "$SETTINGS"

# 5. Report only when something changed
if [[ $changed -eq 1 ]]; then
	echo "permissionsync-cc: hooks installed ($MODE mode)"
fi
