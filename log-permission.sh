#!/usr/bin/env bash
# claude-permission-logger: PermissionRequest hook
# Logs every permission approval to a centralized file, then passes through to the user.
# Install: copy to ~/.claude/hooks/log-permission.sh && chmod +x
#
# The log file (~/.claude/permission-approvals.jsonl) accumulates every tool
# permission you grant across all repos/worktrees.  A companion script
# (sync-permissions.sh) deduplicates and merges them into your global
# ~/.claude/settings.json so you never have to approve the same thing twice.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=permissionsync-lib.sh
source "${SCRIPT_DIR}/permissionsync-lib.sh"

LOG_FILE="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# If we can't parse tool_name, bail and let the normal prompt show
if [[ -z $TOOL_NAME ]]; then
	exit 0
fi

# Build the permission rule using the shared library
build_rule_v2 "$TOOL_NAME" "$TOOL_INPUT"

# Write the approval record (append, atomic-ish via >>)
mkdir -p "$(dirname "$LOG_FILE")"
jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg tool "$TOOL_NAME" \
	--arg rule "${RULE}" \
	--arg exact "${EXACT_RULE:-$RULE}" \
	--arg base_command "${BASE_COMMAND}" \
	--arg indirection_chain "${INDIRECTION_CHAIN}" \
	--arg is_safe "${IS_SAFE}" \
	--arg cwd "$CWD" \
	--arg session "$SESSION_ID" \
	'{timestamp: $ts, tool: $tool, rule: $rule, exact_rule: $exact, base_command: $base_command, indirection_chain: $indirection_chain, is_safe: $is_safe, cwd: $cwd, session_id: $session}' \
	>>"$LOG_FILE"

# Don't make a decision — fall through to the normal interactive prompt.
# The user still approves/denies as usual; we just logged what was requested.
# To auto-approve known rules instead, uncomment below and use sync-permissions.sh
# to build the allowlist first.
exit 0
