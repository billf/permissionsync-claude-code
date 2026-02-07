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

# Build the permission rule string that settings.json expects
RULE=""
case "$TOOL_NAME" in
Bash)
	CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty')
	if [[ -n $CMD ]]; then
		# Extract the first word (the binary) for a wildcard rule
		FIRST_WORD=$(echo "$CMD" | awk '{print $1}')
		RULE="Bash(${FIRST_WORD} *)"
		# Also store the exact command for reference
		EXACT_RULE="Bash(${CMD})"
	else
		RULE="Bash"
	fi
	;;
Read | Write | Edit | MultiEdit)
	FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
	if [[ -n $FILE_PATH ]]; then
		RULE="${TOOL_NAME}"
		EXACT_RULE="${TOOL_NAME}(${FILE_PATH})"
	else
		RULE="$TOOL_NAME"
	fi
	;;
WebFetch)
	URL=$(echo "$TOOL_INPUT" | jq -r '.url // empty')
	if [[ -n $URL ]]; then
		DOMAIN=$(echo "$URL" | sed -E 's|https?://([^/]+).*|\1|')
		RULE="WebFetch(domain:${DOMAIN})"
		EXACT_RULE="$RULE"
	else
		RULE="WebFetch"
	fi
	;;
mcp__*)
	# MCP tools: log the full tool name
	RULE="$TOOL_NAME"
	EXACT_RULE="$TOOL_NAME"
	;;
*)
	RULE="$TOOL_NAME"
	EXACT_RULE="$TOOL_NAME"
	;;
esac

# Write the approval record (append, atomic-ish via >>)
mkdir -p "$(dirname "$LOG_FILE")"
jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg tool "$TOOL_NAME" \
	--arg rule "${RULE}" \
	--arg exact "${EXACT_RULE:-$RULE}" \
	--arg cwd "$CWD" \
	--arg session "$SESSION_ID" \
	'{timestamp: $ts, tool: $tool, rule: $rule, exact_rule: $exact, cwd: $cwd, session_id: $session}' \
	>>"$LOG_FILE"

# Don't make a decision — fall through to the normal interactive prompt.
# The user still approves/denies as usual; we just logged what was requested.
# To auto-approve known rules instead, uncomment below and use sync-permissions.sh
# to build the allowlist first.
exit 0
