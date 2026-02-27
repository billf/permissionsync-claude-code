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
# shellcheck source=permissionsync-lib.sh
source "${SCRIPT_DIR}/permissionsync-lib.sh"

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

INPUT=$(</dev/stdin)

# Parse all fields in a single jq call to minimize subprocess overhead
eval "$(jq -r '@sh "TOOL_NAME=\(.tool_name // "") TOOL_INPUT=\(.tool_input // {} | tostring) CWD=\(.cwd // "")"' <<<"$INPUT")"

[[ -z $TOOL_NAME ]] && exit 0

# --- Build the permission rule using the shared library ---
build_rule_v2 "$TOOL_NAME" "$TOOL_INPUT"

# --- Snapshot whether this rule existed before this invocation ---
SEEN_BEFORE=0
if [[ $AUTO_MODE == "1" ]] && [[ -f $LOG_FILE ]]; then
	if grep -qF "\"rule\":\"${RULE}\"" "$LOG_FILE" 2>/dev/null; then
		SEEN_BEFORE=1
	fi
fi

# --- Log the request ---
mkdir -p "$(dirname "$LOG_FILE")"
jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg tool "$TOOL_NAME" \
	--arg rule "$RULE" \
	--arg base_command "${BASE_COMMAND}" \
	--arg indirection_chain "${INDIRECTION_CHAIN}" \
	--arg is_safe "${IS_SAFE}" \
	--arg cwd "$CWD" \
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

# --- Sibling worktree auto-approve ---
if [[ $WORKTREE_MODE == "1" ]]; then
	if is_in_worktree; then
		if read_sibling_rules; then
			if echo "$SIBLING_RULES" | grep -qxF "$RULE"; then
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
	fi
fi

# --- Auto-approve mode: if this rule was previously approved, allow it ---
if [[ $AUTO_MODE == "1" ]] && [[ $SEEN_BEFORE -eq 1 ]]; then
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

# --- Default: fall through to interactive prompt ---
exit 0
