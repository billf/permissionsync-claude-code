#!/usr/bin/env bash
# sync-permissions.sh
#
# Reads ~/.claude/permission-approvals.jsonl, deduplicates the rules,
# and merges them into ~/.claude/settings.json under permissions.allow.
#
# Usage:
#   ./sync-permissions.sh              # preview what would be added (dry-run)
#   ./sync-permissions.sh --apply      # write to settings.json
#   ./sync-permissions.sh --print      # just print the deduplicated rules as JSON array
#   ./sync-permissions.sh --diff       # show diff between current and proposed
#   ./sync-permissions.sh --refine          # propose replacing broad rules with fine-grained ones
#   ./sync-permissions.sh --refine --apply # write refined rules to settings.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/permissionsync-lib.sh
source "${PERMISSIONSYNC_LIB_DIR:-$SCRIPT_DIR/lib}/permissionsync-lib.sh"

BASE_LOG="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
CONFIRMED_LOG="$(dirname "$BASE_LOG")/confirmed-approvals.jsonl"
LOG_FILE="$BASE_LOG"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Parse flags
REFINE=0
APPLY=0
INIT_BASE=0
FROM_CONFIRMED=0
MODE=""
for arg in "$@"; do
	case "$arg" in
	--refine) REFINE=1 ;;
	--apply) APPLY=1 ;;
	--init-base) INIT_BASE=1 ;;
	--from-confirmed) FROM_CONFIRMED=1 ;;
	--preview | --print | --diff | --stats) MODE="$arg" ;;
	*)
		echo "Usage: $0 [--preview|--apply|--print|--diff|--stats|--refine|--init-base|--from-confirmed] [--apply]"
		exit 1
		;;
	esac
done

# --from-confirmed: use confirmed-approvals.jsonl as the rule source
if [[ $FROM_CONFIRMED -eq 1 ]]; then
	LOG_FILE="$CONFIRMED_LOG"
fi

# Default to --preview if nothing specified
if [[ $REFINE -eq 0 ]] && [[ $APPLY -eq 0 ]] && [[ $INIT_BASE -eq 0 ]] && [[ -z $MODE ]]; then
	MODE="--preview"
fi

# --init-base doesn't need the approval log
if [[ $INIT_BASE -eq 0 ]] && [[ ! -f $LOG_FILE ]]; then
	if [[ $FROM_CONFIRMED -eq 1 ]]; then
		echo "No confirmed-approvals log found at $LOG_FILE"
		echo "Run Claude Code with the PostToolUse hook first (install with --auto or --worktree mode)."
	else
		echo "No approval log found at $LOG_FILE"
		echo "Run Claude Code with the PermissionRequest hook first."
	fi
	exit 1
fi

# filter_rules is now in permissionsync-lib.sh

RULES_FROM_LOG=""
EXISTING_RULES=""
NEW_RULES=""
ALL_RULES=""

if [[ $INIT_BASE -eq 0 ]]; then
	RULES_FROM_LOG=$(jq -r '.rule // empty' "$LOG_FILE" |
		grep -E '^(Bash\(.*\)|WebFetch(\(.*\))?|mcp__.*)$' |
		filter_rules |
		sort -u)

	# --- Read existing allow rules from settings.json ---
	if [[ -f $SETTINGS_FILE ]]; then
		EXISTING_RULES=$(jq -r '.permissions.allow[]? // empty' "$SETTINGS_FILE" 2>/dev/null | sort -u)
	fi

	# --- Compute new rules (in log but not in settings) ---
	# Use comm to find rules in log but not in settings (both already sorted)
	NEW_RULES=$(comm -23 <(echo "$RULES_FROM_LOG" | sed '/^$/d') <(echo "$EXISTING_RULES" | sed '/^$/d'))

	# --- Combine all rules ---
	ALL_RULES=$(printf '%s\n%s' "$EXISTING_RULES" "$RULES_FROM_LOG" | sed '/^$/d' | sort -u)
fi

# expand_safe_direct_rules
#
# For each binary seen in the log that has tracked subcommands, emit
# Bash(binary subcmd *) for all safe subcommands (direct only, no indirection).
expand_safe_direct_rules() {
	# Collect unique binaries from new-format (base_command) and old-format (Bash(bin *)) entries
	local seen_binaries
	seen_binaries=$(
		{
			# New-format: first word of base_command
			jq -r 'select(.base_command != null and .base_command != "") | .base_command | split(" ")[0]' \
				"$LOG_FILE" 2>/dev/null
			# Old-format: extract binary from Bash(BINARY *) rules
			echo "$RULES_FROM_LOG" | sed -n 's/^Bash(\([a-zA-Z0-9_-]*\) \*)/\1/p'
		} | sort -u
	)

	# For each binary with tracked subcommands, emit safe rules
	local bin
	for bin in $seen_binaries; do
		has_subcommands "$bin" || continue
		local safe_list
		safe_list=$(get_safe_subcommands "$bin")
		local alt_prefixes
		alt_prefixes=$(get_alt_rule_prefixes "$bin")
		local word
		for word in $safe_list; do
			if [[ $word == *:* ]]; then
				# Compound key: pr:list → Bash(gh pr list *)
				local parent="${word%%:*}"
				local sub="${word#*:}"
				echo "Bash(${bin} ${parent} ${sub} *)"
			else
				echo "Bash(${bin} ${word} *)"
				# Emit alternative forms (e.g. git -C * log *)
				local prefix
				for prefix in $alt_prefixes; do
					echo "Bash(${bin} ${prefix} * ${word} *)"
				done
			fi
		done
	done
}

# --- Helper: compute refined rules (used by --refine preview and --refine --apply) ---
compute_refined_rules() {
	# Core refinement (sets REFINED_RULES, BROAD_RULES, SAFE_RULES)
	refine_rules_from "$ALL_RULES"

	# Collect observed non-safe subcommand rules from the log (informational only)
	OBSERVED_RULES=""
	local bin subcmd
	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		# Match Bash(BINARY SUBCMD *) pattern
		if [[ $rule =~ ^Bash\(([a-zA-Z0-9_-]+)\ ([a-zA-Z0-9_-]+)\ \*\)$ ]]; then
			bin="${BASH_REMATCH[1]}"
			subcmd="${BASH_REMATCH[2]}"
			if ! is_safe_subcommand "$bin" "$subcmd"; then
				OBSERVED_RULES="${OBSERVED_RULES}${rule}"$'\n'
			fi
		fi
	done <<<"$RULES_FROM_LOG"
	OBSERVED_RULES=$(echo "$OBSERVED_RULES" | sed '/^$/d' | sort -u)
}

# --- Helper: write rules to settings.json ---
write_settings() {
	local allow_rules="$1"
	local label="$2"

	ALLOW_JSON=$(echo "$allow_rules" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')

	# Ensure settings.json exists with valid structure
	if [[ ! -f $SETTINGS_FILE ]]; then
		echo '{}' >"$SETTINGS_FILE"
	fi

	local temp
	temp=$(mktemp)
	trap 'rm -f "$temp"' RETURN

	jq --argjson allow "$ALLOW_JSON" '
      .permissions //= {} |
      .permissions.allow = $allow
    ' "$SETTINGS_FILE" >"$temp"

	if jq empty "$temp" 2>/dev/null; then
		cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
		mv "$temp" "$SETTINGS_FILE"
		trap - RETURN
		echo "Updated $SETTINGS_FILE ($label)"
		echo "Backup at ${SETTINGS_FILE}.bak"
	else
		echo "ERROR: Generated invalid JSON. Aborting."
		exit 1
	fi
}

# --- Helper: locate base-settings.json ---
find_base_settings() {
	local candidates=(
		"${PERMISSIONSYNC_SHARE_DIR:-}/base-settings.json"
		"${SCRIPT_DIR}/../share/permissionsync-cc/base-settings.json"
		"${SCRIPT_DIR}/base-settings.json"
	)
	local c
	for c in "${candidates[@]}"; do
		if [[ -f $c ]]; then
			echo "$c"
			return 0
		fi
	done
	echo "ERROR: base-settings.json not found. Is permissionsync-cc installed via Nix?" >&2
	return 1
}

# --- Dispatch ---
if [[ $INIT_BASE -eq 1 ]]; then
	BASE_SETTINGS=$(find_base_settings) || exit 1

	# Read allow and deny arrays from base settings
	BASE_ALLOW=$(jq -r '.permissions.allow[]? // empty' "$BASE_SETTINGS" | sort -u)
	BASE_DENY=$(jq -r '.permissions.deny[]? // empty' "$BASE_SETTINGS" | sort -u)

	# Read existing settings
	EXISTING_ALLOW=""
	EXISTING_DENY=""
	if [[ -f $SETTINGS_FILE ]]; then
		EXISTING_ALLOW=$(jq -r '.permissions.allow[]? // empty' "$SETTINGS_FILE" 2>/dev/null | sort -u)
		EXISTING_DENY=$(jq -r '.permissions.deny[]? // empty' "$SETTINGS_FILE" 2>/dev/null | sort -u)
	fi

	# Compute new entries
	NEW_ALLOW=$(comm -23 <(echo "$BASE_ALLOW" | sed '/^$/d') <(echo "$EXISTING_ALLOW" | sed '/^$/d'))
	NEW_DENY=$(comm -23 <(echo "$BASE_DENY" | sed '/^$/d') <(echo "$EXISTING_DENY" | sed '/^$/d'))

	# Merge
	MERGED_ALLOW=$(printf '%s\n%s' "$EXISTING_ALLOW" "$BASE_ALLOW" | sed '/^$/d' | sort -u)
	MERGED_DENY=$(printf '%s\n%s' "$EXISTING_DENY" "$BASE_DENY" | sed '/^$/d' | sort -u)

	if [[ $APPLY -eq 1 ]]; then
		if [[ -z $NEW_ALLOW ]] && [[ -z $NEW_DENY ]]; then
			echo "Already in sync with base settings. Nothing to do."
			exit 0
		fi

		ALLOW_JSON=$(echo "$MERGED_ALLOW" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')
		DENY_JSON=$(echo "$MERGED_DENY" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')

		if [[ ! -f $SETTINGS_FILE ]]; then
			echo '{}' >"$SETTINGS_FILE"
		fi

		INIT_TEMP=$(mktemp)
		trap 'rm -f "$INIT_TEMP"' RETURN

		jq --argjson allow "$ALLOW_JSON" --argjson deny "$DENY_JSON" '
		  .permissions //= {} |
		  .permissions.allow = $allow |
		  .permissions.deny = $deny
		' "$SETTINGS_FILE" >"$INIT_TEMP"

		if jq empty "$INIT_TEMP" 2>/dev/null; then
			cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
			mv "$INIT_TEMP" "$SETTINGS_FILE"
			trap - RETURN
			echo "Updated $SETTINGS_FILE (base settings merged)"
			echo "Backup at ${SETTINGS_FILE}.bak"
		else
			echo "ERROR: Generated invalid JSON. Aborting."
			exit 1
		fi

		if [[ -n $NEW_ALLOW ]]; then
			echo ""
			echo "Added allow rules:"
			# shellcheck disable=SC2001
			echo "$NEW_ALLOW" | sed 's/^/  + /'
		fi
		if [[ -n $NEW_DENY ]]; then
			echo ""
			echo "Added deny rules:"
			# shellcheck disable=SC2001
			echo "$NEW_DENY" | sed 's/^/  + /'
		fi
	else
		# Preview mode (default)
		echo "=== Base settings from $BASE_SETTINGS ==="
		echo ""
		echo "Allow rules that would be added:"
		if [[ -n $NEW_ALLOW ]]; then
			# shellcheck disable=SC2001
			echo "$NEW_ALLOW" | sed 's/^/  + /'
		else
			echo "  (none — already in sync)"
		fi
		echo ""
		echo "Deny rules that would be added:"
		if [[ -n $NEW_DENY ]]; then
			# shellcheck disable=SC2001
			echo "$NEW_DENY" | sed 's/^/  + /'
		else
			echo "  (none — already in sync)"
		fi
		echo ""
		echo "Run with --init-base --apply to write to $SETTINGS_FILE"
	fi

elif [[ $REFINE -eq 1 ]]; then
	compute_refined_rules

	if [[ -z $BROAD_RULES ]]; then
		echo "No broad rules found that can be refined."
		exit 0
	fi

	echo "=== Fine-Grained Rule Refinement ==="
	echo ""
	echo "Broad rules that would be replaced:"
	# shellcheck disable=SC2001
	echo "$BROAD_RULES" | sed 's/^/  - /'
	echo ""

	echo "Safe subcommand rules (auto-generated):"
	if [[ -n $SAFE_RULES ]]; then
		# shellcheck disable=SC2001
		echo "$SAFE_RULES" | sed 's/^/  + /'
	else
		echo "  (none)"
	fi
	echo ""

	echo "Observed non-safe subcommand rules (NOT included — add manually if needed):"
	if [[ -n $OBSERVED_RULES ]]; then
		# shellcheck disable=SC2001
		echo "$OBSERVED_RULES" | sed 's/^/    /'
	else
		echo "  (none)"
	fi
	echo ""

	echo "=== Refined result ==="
	echo "$REFINED_RULES" | jq -R -s 'split("\n") | map(select(length > 0))'
	echo ""

	if [[ $APPLY -eq 1 ]]; then
		write_settings "$REFINED_RULES" "refined rules"
	else
		echo "Run with --refine --apply to write refined rules to $SETTINGS_FILE"
	fi

elif [[ $APPLY -eq 1 ]]; then
	if [[ -z $NEW_RULES ]]; then
		echo "Already in sync. Nothing to do."
		exit 0
	fi

	write_settings "$ALL_RULES" "merged rules"
	echo ""
	echo "Added $(echo "$NEW_RULES" | wc -l | tr -d ' ') new rule(s):"
	# shellcheck disable=SC2001
	echo "$NEW_RULES" | sed 's/^/  + /'

else
	case "$MODE" in
	--print)
		echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0))'
		;;

	--preview)
		echo "=== Current rules in $SETTINGS_FILE ==="
		if [[ -n $EXISTING_RULES ]]; then
			# shellcheck disable=SC2001
			echo "$EXISTING_RULES" | sed 's/^/  /'
		else
			echo "  (none)"
		fi
		echo ""
		echo "=== New rules from approval log ==="
		if [[ -n $NEW_RULES ]]; then
			# shellcheck disable=SC2001
			echo "$NEW_RULES" | sed 's/^/  + /'
		else
			echo "  (none — already in sync)"
		fi
		echo ""
		echo "=== Merged result ==="
		echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0))'
		echo ""
		echo "Run with --apply to write to $SETTINGS_FILE"
		echo "Run with --refine to propose fine-grained safe-subcommand rules"
		;;

	--diff)
		CURRENT=$(jq -S '.permissions.allow // []' "$SETTINGS_FILE" 2>/dev/null || echo '[]')
		PROPOSED=$(echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')
		diff <(echo "$CURRENT" | jq '.[]' | sort) <(echo "$PROPOSED" | jq '.[]' | sort) || true
		;;

	--stats)
		jq -s '
          def pct(n; total): if total == 0 then "n/a" else ((n * 100 / total) | floor | tostring) + "%" end;
          {
            total: length,
            auto_approved: ([.[] | select(.auto_approved == "true")] | length),
            deferred:      ([.[] | select(.auto_approved == "false")] | length),
            unknown:       ([.[] | select(.auto_approved == null)] | length),
            is_safe_true:  ([.[] | select(.is_safe == "true")] | length),
            by_tool: (group_by(.tool) | map({key: .[0].tool, value: length}) | from_entries | to_entries | sort_by(-.value) | from_entries),
            top_bash_commands: (
              [.[] | select(.tool == "Bash" and (.base_command // "") != "")]
              | group_by(.base_command)
              | map({key: .[0].base_command, value: length})
              | sort_by(-.value)
              | .[0:10]
              | from_entries
            )
          }
        ' "$LOG_FILE" |
			jq -r '
          "=== permissionsync stats ===",
          "Log: '"$LOG_FILE"'",
          "",
          "Total requests logged:  \(.total)",
          "  auto_approved=true:   \(.auto_approved) (\(if .total > 0 then (.auto_approved * 100 / .total | floor) else 0 end)%)",
          "  auto_approved=false:  \(.deferred) (\(if .total > 0 then (.deferred * 100 / .total | floor) else 0 end)%)",
          (if .unknown > 0 then "  auto_approved=unknown: \(.unknown) (pre-v2 entries)" else empty end),
          "  is_safe=true:         \(.is_safe_true)",
          "",
          "By tool:",
          (.by_tool | to_entries[] | "  \(.key): \(.value)"),
          "",
          "Top Bash base_commands:",
          (.top_bash_commands | to_entries[] | "  \(.key): \(.value)")
        '
		;;

	*)
		echo "Usage: $0 [--preview|--apply|--print|--diff|--stats|--refine] [--apply]"
		exit 1
		;;
	esac
fi
