#!/usr/bin/env bash
# claude-permission-logger: PermissionRequest hook (auto-approve variant)
#
# 1. Logs every permission request to ~/.claude/permission-approvals.jsonl
# 2. Auto-approves safe subcommands (e.g. git status, cargo check) immediately
# 3. On *subsequent* sessions, rules already in the log can be auto-approved
#    via the companion sync script, or you can run this hook in "auto" mode
#    to approve anything previously seen.
#
# Environment:
#   CLAUDE_PERMISSION_LOG   - override log path (default: ~/.claude/permission-approvals.jsonl)
#   CLAUDE_PERMISSION_AUTO  - set to "1" to auto-approve any rule already in the log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=permissionsync-lib.sh
source "${SCRIPT_DIR}/permissionsync-lib.sh"

LOG_FILE="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
AUTO_MODE="${CLAUDE_PERMISSION_AUTO:-0}"
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

[[ -z $TOOL_NAME ]] && exit 0

# --- Build the permission rule using the shared library ---
build_rule_v2 "$TOOL_NAME" "$TOOL_INPUT"

# --- Log the request ---
mkdir -p "$(dirname "$LOG_FILE")"
jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg tool "$TOOL_NAME" \
	--arg rule "$RULE" \
	--arg base_command "${BASE_COMMAND}" \
	--arg indirection_chain "${INDIRECTION_CHAIN}" \
	--arg is_safe "${IS_SAFE}" \
	--arg cwd "$(echo "$INPUT" | jq -r '.cwd // empty')" \
	'{timestamp: $ts, tool: $tool, rule: $rule, base_command: $base_command, indirection_chain: $indirection_chain, is_safe: $is_safe, cwd: $cwd}' \
	>>"$LOG_FILE"

# --- Safe subcommand auto-approve: allow known read-only operations ---
if [[ $IS_SAFE == "true" ]]; then
	jq -nc '{
      "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {
          "behavior": "allow"
        }
      }
    }'
	exit 0
fi

# --- Auto-approve mode: if this rule was previously approved, allow it ---
if [[ $AUTO_MODE == "1" ]] && [[ -f $LOG_FILE ]]; then
	if grep -qF "\"rule\":\"${RULE}\"" "$LOG_FILE" 2>/dev/null; then
		# We've seen and (presumably) approved this before — auto-allow
		jq -nc '{
      "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {
          "behavior": "allow"
        }
      }
    }'
		exit 0
	fi
fi

# --- Default: fall through to interactive prompt ---
exit 0
