#!/usr/bin/env bash
# permissionsync-watch-config.sh: ConfigChange hook — guards permissionsync hook entries
set -euo pipefail

INPUT=$(</dev/stdin)
eval "$(jq -r '@sh "SOURCE=\(.source // "") FILE_PATH=\(.file_path // "") SESSION_ID=\(.session_id // "") CWD=\(.cwd // "")"' <<<"$INPUT")"

# Only act on user_settings changes
[[ "$SOURCE" != "user_settings" ]] && exit 0

SETTINGS_PATH="${FILE_PATH:-$HOME/.claude/settings.json}"
CHANGES_LOG="$HOME/.claude/config-changes.jsonl"

# Permissive if file doesn't exist yet
if [[ ! -f "$SETTINGS_PATH" ]]; then
	exit 0
fi

# Guard: check that our hooks are still present
has_permreq=$(jq -r '[.hooks.PermissionRequest[]?.hooks[]?.command // ""] | map(select(test("/.claude/hooks/"))) | length' "$SETTINGS_PATH" 2>/dev/null || echo 0)
has_postuse=$(jq -r '[.hooks.PostToolUse[]?.hooks[]?.command // ""] | map(select(test("/.claude/hooks/"))) | length' "$SETTINGS_PATH" 2>/dev/null || echo 0)

HOOKS_INTACT=true
if [[ "$has_permreq" -eq 0 ]] || [[ "$has_postuse" -eq 0 ]]; then
	HOOKS_INTACT=false
fi

# Log the change
mkdir -p "$(dirname "$CHANGES_LOG")"
jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg source "$SOURCE" --arg file_path "$SETTINGS_PATH" \
	--argjson hooks_intact "$HOOKS_INTACT" \
	--arg session "$SESSION_ID" --arg cwd "$CWD" \
	'{timestamp:$ts, source:$source, file_path:$file_path, hooks_intact:$hooks_intact, session_id:$session, cwd:$cwd}' \
	>>"$CHANGES_LOG"

if [[ "$HOOKS_INTACT" == "false" ]]; then
	echo "permissionsync-cc: hooks removed from $SETTINGS_PATH — blocking change" >&2
	exit 2
fi
exit 0
