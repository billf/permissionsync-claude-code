#!/usr/bin/env bash
# sync-permissions.sh
#
# Reads ~/.claude/permission-approvals.jsonl, deduplicates the rules,
# and merges them into ~/.claude/settings.json under permissions.allow.
#
# Usage:
#   ./sync-permissions.sh              # preview what would be added (dry-run)
#   ./sync-permissions.sh --apply      # write to settings.json
#   ./sync-permissions.sh --print      # just print the deduplicated rules as JSON array
#   ./sync-permissions.sh --diff       # show diff between current and proposed

set -euo pipefail

LOG_FILE="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
SETTINGS_FILE="$HOME/.claude/settings.json"
MODE="${1:---preview}"

if [[ ! -f "$LOG_FILE" ]]; then
	echo "No approval log found at $LOG_FILE"
	echo "Run Claude Code with the PermissionRequest hook first."
	exit 1
fi

# --- Extract unique rules from the log ---
RULES_FROM_LOG=$(jq -r '.rule' "$LOG_FILE" | sort -u)

# --- Read existing allow rules from settings.json ---
EXISTING_RULES=""
if [[ -f "$SETTINGS_FILE" ]]; then
	EXISTING_RULES=$(jq -r '.permissions.allow[]? // empty' "$SETTINGS_FILE" 2>/dev/null | sort -u)
fi

# --- Compute new rules (in log but not in settings) ---
NEW_RULES=""
while IFS= read -r rule; do
	[[ -z "$rule" ]] && continue
	if ! echo "$EXISTING_RULES" | grep -qxF "$rule"; then
		NEW_RULES="${NEW_RULES}${rule}"$'\n'
	fi
done <<<"$RULES_FROM_LOG"
NEW_RULES=$(echo "$NEW_RULES" | sed '/^$/d' | sort -u)

# --- Combine all rules ---
ALL_RULES=$(printf '%s\n%s' "$EXISTING_RULES" "$RULES_FROM_LOG" | sed '/^$/d' | sort -u)

case "$MODE" in
--print)
	echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0))'
	;;

--preview)
	echo "=== Current rules in $SETTINGS_FILE ==="
	if [[ -n "$EXISTING_RULES" ]]; then
		# shellcheck disable=SC2001
		echo "$EXISTING_RULES" | sed 's/^/  /'
	else
		echo "  (none)"
	fi
	echo ""
	echo "=== New rules from approval log ==="
	if [[ -n "$NEW_RULES" ]]; then
		# shellcheck disable=SC2001
		echo "$NEW_RULES" | sed 's/^/  + /'
	else
		echo "  (none — already in sync)"
	fi
	echo ""
	echo "=== Merged result ==="
	echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0))'
	echo ""
	echo "Run with --apply to write to $SETTINGS_FILE"
	;;

--diff)
	CURRENT=$(jq -S '.permissions.allow // []' "$SETTINGS_FILE" 2>/dev/null || echo '[]')
	PROPOSED=$(echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')
	diff <(echo "$CURRENT" | jq '.[]' | sort) <(echo "$PROPOSED" | jq '.[]' | sort) || true
	;;

--apply)
	if [[ -z "$NEW_RULES" ]]; then
		echo "Already in sync. Nothing to do."
		exit 0
	fi

	# Build the merged allow array
	ALLOW_JSON=$(echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')

	# Ensure settings.json exists with valid structure
	if [[ ! -f "$SETTINGS_FILE" ]]; then
		echo '{}' >"$SETTINGS_FILE"
	fi

	# Merge into settings.json, preserving all other keys
	TEMP=$(mktemp)
	jq --argjson allow "$ALLOW_JSON" '
      .permissions //= {} |
      .permissions.allow = $allow
    ' "$SETTINGS_FILE" >"$TEMP"

	# Safety: validate JSON before overwriting
	if jq empty "$TEMP" 2>/dev/null; then
		cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
		mv "$TEMP" "$SETTINGS_FILE"
		echo "Updated $SETTINGS_FILE"
		echo "Backup at ${SETTINGS_FILE}.bak"
		echo ""
		echo "Added $(echo "$NEW_RULES" | wc -l | tr -d ' ') new rule(s):"
		# shellcheck disable=SC2001
		echo "$NEW_RULES" | sed 's/^/  + /'
	else
		echo "ERROR: Generated invalid JSON. Aborting."
		rm -f "$TEMP"
		exit 1
	fi
	;;

*)
	echo "Usage: $0 [--preview|--apply|--print|--diff]"
	exit 1
	;;
esac
