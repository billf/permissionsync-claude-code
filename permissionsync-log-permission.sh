#!/usr/bin/env bash
# permissionsync-hook: PermissionRequest hook
#
# 1. Logs every permission request to ~/.claude/permission-approvals.jsonl
# 2. Auto-approves curated safe subcommands (e.g. git status, cargo check)
# 3. Optionally auto-approves previously-seen rules from the log
# 4. Optionally auto-approves rules from sibling worktrees
#
# Environment (choose one):
#   CLAUDE_PERMISSION_MODE=log       # log only, interactive prompt for everything else
#   CLAUDE_PERMISSION_MODE=auto      # log + auto-approve previously-seen rules
#   CLAUDE_PERMISSION_MODE=worktree  # log + auto-approve from sibling worktrees + history
#
# Legacy environment (still supported for backward compatibility):
#   CLAUDE_PERMISSION_AUTO=1         # same as MODE=auto
#   CLAUDE_PERMISSION_WORKTREE=1     # same as MODE=worktree (also enables auto)
#
# Other:
#   CLAUDE_PERMISSION_LOG            # override log path (default: ~/.claude/permission-approvals.jsonl)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/permissionsync-lib.sh
source "${PERMISSIONSYNC_LIB_DIR:-$SCRIPT_DIR/lib}/permissionsync-lib.sh"

LOG_FILE="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"

# Resolve CLAUDE_PERMISSION_MODE from the enum or legacy vars
_MODE="${CLAUDE_PERMISSION_MODE:-}"
if [[ -z $_MODE ]]; then
	# Legacy: CLAUDE_PERMISSION_WORKTREE=1 implies worktree mode
	if [[ ${CLAUDE_PERMISSION_WORKTREE:-0} == "1" ]]; then
		_MODE="worktree"
	elif [[ ${CLAUDE_PERMISSION_AUTO:-0} == "1" ]]; then
		_MODE="auto"
	else
		_MODE="log"
	fi
fi

AUTO_MODE="0"
WORKTREE_MODE="0"
case "$_MODE" in
worktree)
	AUTO_MODE="1"
	WORKTREE_MODE="1"
	;;
auto)
	AUTO_MODE="1"
	;;
*) ;;
esac

# is_coarse_bare_rule RULE → 0 if RULE is a broad bare matcher that should
# never be auto-approved from history/worktree replay.
# Exact non-parenthesized rules (e.g. mcp__server__tool) are allowed.
is_coarse_bare_rule() {
	case "$1" in
	Bash | Read | Write | Edit | MultiEdit | WebFetch)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

INPUT=$(</dev/stdin)

# Parse all fields in a single jq call to minimize subprocess overhead
eval "$(jq -r '@sh "TOOL_NAME=\(.tool_name // "") TOOL_INPUT=\(.tool_input // {} | tostring) CWD=\(.cwd // "")"' <<<"$INPUT")"

[[ -z $TOOL_NAME ]] && exit 0

# --- Build the permission rule using the shared library ---
build_rule_v2 "$TOOL_NAME" "$TOOL_INPUT"

# --- Snapshot whether this rule existed before this invocation ---
SEEN_BEFORE=0
# Only check history for specific rules.
# Coarse bare rules like "Bash" and "Read" are too broad for replay.
if [[ $AUTO_MODE == "1" ]] && [[ -f $LOG_FILE ]] && ! is_coarse_bare_rule "$RULE"; then
	if grep -qF "\"rule\":\"${RULE}\"" "$LOG_FILE" 2>/dev/null; then
		SEEN_BEFORE=1
	fi
fi

# --- Determine auto-approval decision before logging ---
AUTO_APPROVED="false"

# Safe subcommand auto-approve: allow known read-only operations
if [[ $IS_SAFE == "true" ]]; then
	AUTO_APPROVED="true"

# Sibling worktree auto-approve
elif [[ $WORKTREE_MODE == "1" ]] && is_in_worktree; then
	if read_sibling_rules && echo "$SIBLING_RULES" | grep -qxF "$RULE"; then
		AUTO_APPROVED="true"
	fi
fi

# Auto-approve mode: if this rule was previously seen, allow it
if [[ $AUTO_APPROVED == "false" ]] && [[ $AUTO_MODE == "1" ]] && [[ $SEEN_BEFORE -eq 1 ]]; then
	AUTO_APPROVED="true"
fi

# Safety net: never auto-approve coarse bare rules.
# "Bash" groups ALL unclassifiable commands (blocked interpreters, shell keywords,
# invalid syntax), and file-tool bare rules are broad across all paths.
if is_coarse_bare_rule "$RULE"; then
	AUTO_APPROVED="false"
fi

# --- Log the request with the decision ---
mkdir -p "$(dirname "$LOG_FILE")"
jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg tool "$TOOL_NAME" \
	--arg rule "$RULE" \
	--arg base_command "${BASE_COMMAND}" \
	--arg indirection_chain "${INDIRECTION_CHAIN}" \
	--arg is_safe "${IS_SAFE}" \
	--arg auto_approved "$AUTO_APPROVED" \
	--arg cwd "$CWD" \
	'{timestamp: $ts, tool: $tool, rule: $rule, base_command: $base_command, indirection_chain: $indirection_chain, is_safe: $is_safe, auto_approved: $auto_approved, cwd: $cwd}' \
	>>"$LOG_FILE"

# --- Emit allow decision if auto-approved ---
if [[ $AUTO_APPROVED == "true" ]]; then
	jq -nc '{
      "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {
          "behavior": "allow"
        }
      }
    }'
fi
exit 0
