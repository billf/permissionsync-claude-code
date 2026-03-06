#!/usr/bin/env bash
# permissionsync-worktree-sync.sh — aggregate and sync permission rules across git worktrees
#
# Reads .claude/settings.local.json from all worktrees of the current repo,
# aggregates rules, and can sync them to one or all worktrees.
#
# Usage:
#   worktree-sync.sh                    # preview aggregated rules (default)
#   worktree-sync.sh --preview          # same as above
#   worktree-sync.sh --apply            # write aggregated rules to current worktree
#   worktree-sync.sh --apply-all        # write aggregated rules to ALL worktrees
#   worktree-sync.sh --report           # show which rules appear in how many worktrees
#   worktree-sync.sh --diff             # diff current worktree vs aggregated
#   worktree-sync.sh --refine           # apply safe-subcommand refinement
#   worktree-sync.sh --refine --apply   # refine + write to current worktree
#   worktree-sync.sh --from-log         # also include rules from JSONL log
#   worktree-sync.sh --sanitize         # remove invalid entries from all worktree settings
#
# Environment:
#   CLAUDE_PERMISSION_LOG  - override log path (default: ~/.claude/permission-approvals.jsonl)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/permissionsync-lib.sh
source "${PERMISSIONSYNC_LIB_DIR:-$SCRIPT_DIR/lib}/permissionsync-lib.sh"

LOG_FILE="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"

# Parse flags
REFINE=0
APPLY=0
APPLY_ALL=0
FROM_LOG=0
SANITIZE=0
MODE=""
for arg in "$@"; do
	case "$arg" in
	--refine) REFINE=1 ;;
	--apply) APPLY=1 ;;
	--apply-all) APPLY_ALL=1 ;;
	--from-log) FROM_LOG=1 ;;
	--sanitize) SANITIZE=1 ;;
	--preview | --report | --diff) MODE="$arg" ;;
	*)
		echo "Usage: $0 [--preview|--apply|--apply-all|--report|--diff|--refine|--sanitize] [--apply] [--from-log]"
		exit 1
		;;
	esac
done
# Default to --preview if nothing specified
if [[ $REFINE -eq 0 ]] && [[ $APPLY -eq 0 ]] && [[ $APPLY_ALL -eq 0 ]] && [[ $SANITIZE -eq 0 ]] && [[ -z $MODE ]]; then
	MODE="--preview"
fi

# ============================================================
# Discover worktrees
# ============================================================

if ! discover_worktrees 0; then
	echo "Error: not in a git repository." >&2
	exit 1
fi

if [[ $WORKTREE_COUNT -lt 2 ]]; then
	# Include current, so count==1 means no siblings
	echo "No sibling worktrees found. Nothing to sync."
	exit 0
fi

CURRENT_WT=$(git rev-parse --show-toplevel 2>/dev/null)

# ============================================================
# Collect rules from all worktrees
# ============================================================

# Collect all rules with their source worktree (one per line: "RULE\tPATH")
ALL_TAGGED_RULES=""
for ((i = 0; i < WORKTREE_COUNT; i++)); do
	wt="${WORKTREE_PATHS[$i]}"
	settings_file="${wt}/.claude/settings.local.json"
	[[ -f $settings_file ]] || continue
	rules=$(jq -r '.permissions.allow[]? // empty' "$settings_file" 2>/dev/null |
		validate_rules) || continue
	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		ALL_TAGGED_RULES="${ALL_TAGGED_RULES}${rule}	${wt}"$'\n'
	done <<<"$rules"
done

# Deduplicated rules only
ALL_RULES=$(echo "$ALL_TAGGED_RULES" | cut -f1 | sed '/^$/d' | sort -u)

# ============================================================
# Optionally include rules from JSONL log
# ============================================================

if [[ $FROM_LOG -eq 1 ]] && [[ -f $LOG_FILE ]]; then
	# Build a jq filter using startswith for each worktree path (no regex injection surface)
	jq_expr='select(.cwd != null and ('
	sep=''
	for ((i = 0; i < WORKTREE_COUNT; i++)); do
		jq_expr+="${sep}(.cwd | startswith(\$wt${i}))"
		sep=' or '
	done
	jq_expr+='))'

	# Build --arg args for each worktree path
	jq_args=()
	for ((i = 0; i < WORKTREE_COUNT; i++)); do
		jq_args+=(--arg "wt${i}" "${WORKTREE_PATHS[$i]}")
	done

	# Filter log for entries matching worktree CWDs, extract rules
	log_rules=$(jq -r "${jq_args[@]}" \
		"${jq_expr} | select((.rule // \"\") | test(\"[\\\\n\\\\r]\") | not) | .rule // empty" \
		"$LOG_FILE" 2>/dev/null |
		grep -E '^(Bash\(.*\)|WebFetch(\(.*\))?|mcp__.*)$' |
		filter_rules |
		sort -u) || true

	if [[ -n $log_rules ]]; then
		ALL_RULES=$(printf '%s\n%s' "$ALL_RULES" "$log_rules" | sed '/^$/d' | sort -u)
	fi
fi

# ============================================================
# Current worktree rules
# ============================================================

CURRENT_RULES=""
CURRENT_SETTINGS="${CURRENT_WT}/.claude/settings.local.json"
if [[ -f $CURRENT_SETTINGS ]]; then
	CURRENT_RULES=$(jq -r '.permissions.allow[]? // empty' "$CURRENT_SETTINGS" 2>/dev/null |
		validate_rules | sort -u)
fi

# New rules (in aggregate but not in current)
NEW_TO_CURRENT=$(comm -23 <(echo "$ALL_RULES" | sed '/^$/d') <(echo "$CURRENT_RULES" | sed '/^$/d'))

# ============================================================
# Frequency report helper
# ============================================================

build_frequency_report() {
	# Count how many worktrees each rule appears in
	echo "$ALL_TAGGED_RULES" | cut -f1 | sed '/^$/d' | sort | uniq -c | sort -rn
}

# ============================================================
# Write rules to a settings.local.json
# ============================================================

write_local_settings() {
	local target_path="$1"
	local rules="$2"
	local label="$3"

	# Defense-in-depth: re-validate before persisting
	rules=$(echo "$rules" | validate_rules)

	local allow_json
	allow_json=$(echo "$rules" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')

	local settings_file="${target_path}/.claude/settings.local.json"
	mkdir -p "${target_path}/.claude"

	if [[ ! -f $settings_file ]]; then
		echo '{}' >"$settings_file"
	fi

	local temp
	temp=$(mktemp)
	trap 'rm -f "$temp"' RETURN

	jq --argjson allow "$allow_json" '
      .permissions //= {} |
      .permissions.allow = $allow
    ' "$settings_file" >"$temp"

	if jq empty "$temp" 2>/dev/null; then
		if [[ -f $settings_file ]] && ! cmp -s "$settings_file" "$temp"; then
			cp "$settings_file" "${settings_file}.bak"
		fi
		mv "$temp" "$settings_file"
		trap - RETURN
		echo "Updated ${settings_file} (${label})"
	else
		echo "ERROR: Generated invalid JSON for ${settings_file}. Aborting." >&2
		rm -f "$temp"
		trap - RETURN
		return 1
	fi
}

# ============================================================
# Dispatch
# ============================================================

if [[ $SANITIZE -eq 1 ]]; then
	# Cleanup: filter invalid entries from all worktree settings
	# --sanitize alone previews; --sanitize --apply writes
	dirty_count=0
	for ((i = 0; i < WORKTREE_COUNT; i++)); do
		settings_file="${WORKTREE_PATHS[$i]}/.claude/settings.local.json"
		[[ -f $settings_file ]] || continue
		# Re-reads raw rules (can't reuse ALL_TAGGED_RULES — sanitize
		# needs the unvalidated input to compute the diff)
		raw_rules=$(jq -r '.permissions.allow[]? // empty' "$settings_file" 2>/dev/null) || continue
		clean_rules=$(echo "$raw_rules" | filter_rules | sort -u)
		removed_rules=$(comm -23 \
			<(echo "$raw_rules" | sed '/^$/d' | sort -u) \
			<(echo "$clean_rules" | sed '/^$/d'))
		if [[ -n $removed_rules ]]; then
			removed_count=$(echo "$removed_rules" | wc -l | tr -d ' ')
			echo "=== ${WORKTREE_PATHS[$i]} (${removed_count} invalid) ==="
			# shellcheck disable=SC2001
			echo "$removed_rules" | sed 's/^/  - /'
			if [[ $APPLY -eq 1 ]] || [[ $APPLY_ALL -eq 1 ]]; then
				write_local_settings "${WORKTREE_PATHS[$i]}" "$clean_rules" "sanitized: removed ${removed_count} invalid entries"
			fi
			dirty_count=$((dirty_count + 1))
		fi
	done
	if [[ $dirty_count -eq 0 ]]; then
		echo "All worktree settings are clean. Nothing to sanitize."
	elif [[ $APPLY -eq 1 ]] || [[ $APPLY_ALL -eq 1 ]]; then
		echo ""
		echo "Sanitized ${dirty_count} worktree settings file(s)."
	else
		echo ""
		echo "Found ${dirty_count} worktree(s) with invalid entries."
		echo "Run with --sanitize --apply to clean them."
	fi

elif [[ $REFINE -eq 1 ]]; then
	# Core refinement (sets REFINED_RULES, BROAD_RULES, SAFE_RULES)
	refine_rules_from "$ALL_RULES"

	if [[ -z $BROAD_RULES ]]; then
		echo "No broad rules found that can be refined."
		exit 0
	fi

	echo "=== Fine-Grained Rule Refinement (Worktree Aggregate) ==="
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
	echo "=== Refined result ==="
	echo "$REFINED_RULES" | jq -R -s 'split("\n") | map(select(length > 0))'
	echo ""

	if [[ $APPLY -eq 1 ]]; then
		write_local_settings "$CURRENT_WT" "$REFINED_RULES" "refined worktree rules"
	elif [[ $APPLY_ALL -eq 1 ]]; then
		for ((i = 0; i < WORKTREE_COUNT; i++)); do
			write_local_settings "${WORKTREE_PATHS[$i]}" "$REFINED_RULES" "refined worktree rules"
		done
	else
		echo "Run with --refine --apply to write refined rules to current worktree"
		echo "Run with --refine --apply-all to write refined rules to ALL worktrees"
	fi

elif [[ $APPLY -eq 1 ]]; then
	if [[ -z $NEW_TO_CURRENT ]]; then
		echo "Already in sync. Nothing to do."
		exit 0
	fi

	write_local_settings "$CURRENT_WT" "$ALL_RULES" "aggregated worktree rules"
	echo ""
	echo "Added $(echo "$NEW_TO_CURRENT" | wc -l | tr -d ' ') new rule(s):"
	# shellcheck disable=SC2001
	echo "$NEW_TO_CURRENT" | sed 's/^/  + /'

elif [[ $APPLY_ALL -eq 1 ]]; then
	for ((i = 0; i < WORKTREE_COUNT; i++)); do
		write_local_settings "${WORKTREE_PATHS[$i]}" "$ALL_RULES" "aggregated worktree rules"
	done
	echo ""
	echo "Synced $(echo "$ALL_RULES" | wc -l | tr -d ' ') rule(s) to ${WORKTREE_COUNT} worktrees"

else
	case "$MODE" in
	--preview)
		echo "=== Worktrees (${WORKTREE_COUNT}) ==="
		for ((i = 0; i < WORKTREE_COUNT; i++)); do
			local_settings="${WORKTREE_PATHS[$i]}/.claude/settings.local.json"
			local_count=0
			if [[ -f $local_settings ]]; then
				local_count=$(jq '[.permissions.allow[]?] | length' "$local_settings" 2>/dev/null || echo 0)
			fi
			marker=""
			if [[ ${WORKTREE_PATHS[$i]} == "$CURRENT_WT" ]]; then
				marker=" (current)"
			fi
			echo "  ${WORKTREE_PATHS[$i]}${marker} — ${local_count} rules"
		done
		echo ""
		echo "=== Current worktree rules ==="
		if [[ -n $CURRENT_RULES ]]; then
			# shellcheck disable=SC2001
			echo "$CURRENT_RULES" | sed 's/^/  /'
		else
			echo "  (none)"
		fi
		echo ""
		echo "=== New rules from sibling worktrees ==="
		if [[ -n $NEW_TO_CURRENT ]]; then
			# shellcheck disable=SC2001
			echo "$NEW_TO_CURRENT" | sed 's/^/  + /'
		else
			echo "  (none — already in sync)"
		fi
		echo ""
		echo "=== Aggregated rules ==="
		echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0))'
		echo ""
		echo "Run with --apply to write to current worktree's settings.local.json"
		echo "Run with --apply-all to write to ALL worktrees"
		;;

	--report)
		echo "=== Rule Frequency Report ==="
		echo ""
		echo "  Count  Rule"
		echo "  -----  ----"
		build_frequency_report | while IFS= read -r line; do
			echo "  ${line}"
		done
		echo ""
		echo "Total: $(echo "$ALL_RULES" | wc -l | tr -d ' ') unique rules across ${WORKTREE_COUNT} worktrees"
		;;

	--diff)
		current_json=$(echo "$CURRENT_RULES" | jq -R -s 'split("\n") | map(select(length > 0)) | sort | .[]' 2>/dev/null || true)
		aggregated_json=$(echo "$ALL_RULES" | jq -R -s 'split("\n") | map(select(length > 0)) | sort | .[]' 2>/dev/null || true)
		diff <(echo "$current_json") <(echo "$aggregated_json") || true
		;;

	*)
		echo "Usage: $0 [--preview|--apply|--apply-all|--report|--diff|--refine] [--apply] [--from-log]"
		exit 1
		;;
	esac
fi
