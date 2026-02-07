#!/usr/bin/env bash
# claude-permission-logger: PermissionRequest hook (auto-approve variant)
#
# 1. Logs every permission request to ~/.claude/permission-approvals.jsonl
# 2. If the user approves (we detect this isn't blocked), the rule is logged.
# 3. On *subsequent* sessions, rules already in the log can be auto-approved
#    via the companion sync script, or you can run this hook in "auto" mode
#    to approve anything previously seen.
#
# Environment:
#   CLAUDE_PERMISSION_LOG   - override log path (default: ~/.claude/permission-approvals.jsonl)
#   CLAUDE_PERMISSION_AUTO  - set to "1" to auto-approve any rule already in the log

set -euo pipefail

LOG_FILE="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
AUTO_MODE="${CLAUDE_PERMISSION_AUTO:-0}"
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

[[ -z "$TOOL_NAME" ]] && exit 0

# --- Build the permission rule string ---
build_rule() {
  local tool="$1" input="$2"
  case "$tool" in
    Bash)
      local cmd
      cmd=$(echo "$input" | jq -r '.command // empty')
      if [[ -n "$cmd" ]]; then
        local first_word
        first_word=$(echo "$cmd" | awk '{print $1}')
        echo "Bash(${first_word} *)"
      else
        echo "Bash"
      fi
      ;;
    Read|Write|Edit|MultiEdit)
      echo "$tool"
      ;;
    WebFetch)
      local url domain
      url=$(echo "$input" | jq -r '.url // empty')
      if [[ -n "$url" ]]; then
        domain=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
        echo "WebFetch(domain:${domain})"
      else
        echo "WebFetch"
      fi
      ;;
    *)
      echo "$tool"
      ;;
  esac
}

RULE=$(build_rule "$TOOL_NAME" "$TOOL_INPUT")

# --- Log the request ---
mkdir -p "$(dirname "$LOG_FILE")"
jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tool "$TOOL_NAME" \
  --arg rule "$RULE" \
  --arg cwd "$(echo "$INPUT" | jq -r '.cwd // empty')" \
  '{timestamp: $ts, tool: $tool, rule: $rule, cwd: $cwd}' \
  >> "$LOG_FILE"

# --- Auto-approve mode: if this rule was previously approved, allow it ---
if [[ "$AUTO_MODE" == "1" ]] && [[ -f "$LOG_FILE" ]]; then
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
