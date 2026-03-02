#!/usr/bin/env bash
# log-confirmed.sh: PostToolUse hook — logs confirmed (approved + executed) operations
#
# Fires only when a tool successfully executes. Appends to confirmed-approvals.jsonl,
# giving a clean "definitely approved" signal distinct from the PermissionRequest log
# (which also captures denied requests).
#
# Environment:
#   CLAUDE_PERMISSION_LOG  - base log path (default: ~/.claude/permission-approvals.jsonl)
#                            Confirmed log goes to the same directory:
#                            ~/.claude/confirmed-approvals.jsonl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/permissionsync-lib.sh
source "$SCRIPT_DIR/lib/permissionsync-lib.sh"

BASE_LOG="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
CONFIRMED_LOG="$(dirname "$BASE_LOG")/confirmed-approvals.jsonl"

INPUT=$(</dev/stdin)

# Parse fields in a single jq call
eval "$(jq -r '@sh "TOOL_NAME=\(.tool_name // "") TOOL_INPUT=\(.tool_input // {} | tostring) CWD=\(.cwd // "") SESSION_ID=\(.session_id // "")"' <<<"$INPUT")"

[[ -z $TOOL_NAME ]] && exit 0

# Build the rule using the shared library
build_rule_v2 "$TOOL_NAME" "$TOOL_INPUT"

# Append confirmed approval record
mkdir -p "$(dirname "$CONFIRMED_LOG")"
jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg tool "$TOOL_NAME" \
	--arg rule "$RULE" \
	--arg base_command "${BASE_COMMAND}" \
	--arg indirection_chain "${INDIRECTION_CHAIN}" \
	--arg is_safe "${IS_SAFE}" \
	--arg cwd "$CWD" \
	--arg session "$SESSION_ID" \
	'{timestamp: $ts, tool: $tool, rule: $rule, base_command: $base_command, indirection_chain: $indirection_chain, is_safe: $is_safe, cwd: $cwd, session_id: $session}' \
	>>"$CONFIRMED_LOG"
