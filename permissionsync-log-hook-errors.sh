#!/usr/bin/env bash
# permissionsync-log-hook-errors.sh: PostToolUseFailure hook — logs failed tool executions
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/permissionsync-lib.sh
source "${PERMISSIONSYNC_LIB_DIR:-$SCRIPT_DIR/lib}/permissionsync-lib.sh"

BASE_LOG="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
ERRORS_LOG="$(dirname "$BASE_LOG")/hook-errors.jsonl"

INPUT=$(</dev/stdin)
eval "$(jq -r '@sh "TOOL_NAME=\(.tool_name // "") TOOL_INPUT=\(.tool_input // {} | tostring) ERROR=\(.error // "") ERROR_MSG=\(.error_message // "") CWD=\(.cwd // "") SESSION_ID=\(.session_id // "")"' <<<"$INPUT")"

[[ -z $TOOL_NAME ]] && exit 0

build_rule_v2 "$TOOL_NAME" "$TOOL_INPUT"

mkdir -p "$(dirname "$ERRORS_LOG")"
jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg tool "$TOOL_NAME" --arg rule "$RULE" \
	--arg base_command "${BASE_COMMAND}" \
	--arg indirection_chain "${INDIRECTION_CHAIN}" \
	--arg is_safe "${IS_SAFE}" \
	--arg error "$ERROR" --arg error_message "$ERROR_MSG" \
	--arg cwd "$CWD" --arg session "$SESSION_ID" \
	'{timestamp:$ts, tool:$tool, rule:$rule, base_command:$base_command, indirection_chain:$indirection_chain, is_safe:$is_safe, error:$error, error_message:$error_message, cwd:$cwd, session_id:$session}' \
	>>"$ERRORS_LOG"
# Always exit 0 — PostToolUseFailure cannot block
exit 0
