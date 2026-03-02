#!/usr/bin/env bash
# merged-settings.sh — output merged permissions JSON for claude --settings
#
# Merges global settings, worktree rules, and optionally JSONL log rules
# into a single JSON document on stdout. Designed for use with process
# substitution: claude --worktree -w name --settings <(merged-settings.sh)
#
# All diagnostic messages go to stderr. stdout is pure JSON only.
#
# Usage:
#   merged-settings.sh              # merge global + all worktree rules
#   merged-settings.sh --refine     # also apply safe-subcommand refinement
#   merged-settings.sh --from-log   # also include JSONL approval log rules
#   merged-settings.sh --global-only # skip worktree discovery, global only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=permissionsync-lib.sh
source "${SCRIPT_DIR}/permissionsync-lib.sh"

SETTINGS_FILE="$HOME/.claude/settings.json"
LOG_FILE="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"

# Parse flags
REFINE=0
FROM_LOG=0
GLOBAL_ONLY=0
for arg in "$@"; do
	case "$arg" in
	--merged) ;; # default, no-op
	--refine) REFINE=1 ;;
	--from-log) FROM_LOG=1 ;;
	--global-only) GLOBAL_ONLY=1 ;;
	*)
		echo "Usage: $0 [--merged|--refine|--from-log|--global-only]" >&2
		exit 1
		;;
	esac
done

# ============================================================
# 1. Read global settings
# ============================================================

ALLOW_RULES=""
DENY_RULES=""

if [[ -f $SETTINGS_FILE ]]; then
	ALLOW_RULES=$(jq -r '.permissions.allow[]? // empty' "$SETTINGS_FILE" 2>/dev/null) || true
	DENY_RULES=$(jq -r '.permissions.deny[]? // empty' "$SETTINGS_FILE" 2>/dev/null) || true
fi

# ============================================================
# 2. Collect worktree rules (unless --global-only)
# ============================================================

if [[ $GLOBAL_ONLY -eq 0 ]]; then
	if git rev-parse --git-dir >/dev/null 2>&1; then
		if discover_worktrees 0 2>/dev/null; then
			for ((i = 0; i < WORKTREE_COUNT; i++)); do
				settings_file="${WORKTREE_PATHS[$i]}/.claude/settings.local.json"
				[[ -f $settings_file ]] || continue
				wt_rules=$(jq -r '.permissions.allow[]? // empty' "$settings_file" 2>/dev/null) || continue
				if [[ -n $wt_rules ]]; then
					ALLOW_RULES="${ALLOW_RULES}"$'\n'"${wt_rules}"
				fi
			done
		fi
	fi
fi

# ============================================================
# 3. Include JSONL log rules (if --from-log)
# ============================================================

if [[ $FROM_LOG -eq 1 ]] && [[ -f $LOG_FILE ]]; then
	log_rules=$(jq -r '.rule // empty' "$LOG_FILE" 2>/dev/null |
		grep -E '^(Bash\(.*\)|WebFetch(\(.*\))?|mcp__.*)$') || true
	if [[ -n $log_rules ]]; then
		ALLOW_RULES="${ALLOW_RULES}"$'\n'"${log_rules}"
	fi
fi

# ============================================================
# 4. Deduplicate and filter
# ============================================================

ALLOW_RULES=$(echo "$ALLOW_RULES" | sed '/^$/d' | sort -u | filter_rules)
DENY_RULES=$(echo "$DENY_RULES" | sed '/^$/d' | sort -u)

# ============================================================
# 5. Refine (if --refine)
# ============================================================

if [[ $REFINE -eq 1 ]] && [[ -n $ALLOW_RULES ]]; then
	refine_rules_from "$ALLOW_RULES"
	ALLOW_RULES="$REFINED_RULES"
fi

# ============================================================
# 6. Output JSON to stdout
# ============================================================

ALLOW_JSON=$(echo "$ALLOW_RULES" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')
DENY_JSON=$(echo "$DENY_RULES" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')

jq -n --argjson allow "$ALLOW_JSON" --argjson deny "$DENY_JSON" \
	'{"permissions":{"allow":$allow,"deny":$deny}}'
