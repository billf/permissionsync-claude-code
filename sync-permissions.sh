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
# shellcheck source=permissionsync-lib.sh
source "${SCRIPT_DIR}/permissionsync-lib.sh"

LOG_FILE="${CLAUDE_PERMISSION_LOG:-$HOME/.claude/permission-approvals.jsonl}"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Parse flags
REFINE=0
APPLY=0
MODE=""
for arg in "$@"; do
	case "$arg" in
	--refine) REFINE=1 ;;
	--apply) APPLY=1 ;;
	--preview | --print | --diff) MODE="$arg" ;;
	*)
		echo "Usage: $0 [--preview|--apply|--print|--diff|--refine] [--apply]"
		exit 1
		;;
	esac
done
# Default to --preview if nothing specified
if [[ $REFINE -eq 0 ]] && [[ $APPLY -eq 0 ]] && [[ -z $MODE ]]; then
	MODE="--preview"
fi

if [[ ! -f $LOG_FILE ]]; then
	echo "No approval log found at $LOG_FILE"
	echo "Run Claude Code with the PermissionRequest hook first."
	exit 1
fi

# --- Extract unique rules from the log, filtering out garbage ---
# Valid permission rules are either:
#   ToolName(args...)  — e.g. Bash(git *), WebFetch(domain:example.com)
#   ToolName           — bare tool name (Read, Write, Edit, MultiEdit, WebFetch)
#   mcp__*             — MCP tool names
# Also filters out rules for blocklisted binaries (shells/interpreters).
filter_rules() {
	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		# Extract the binary from Bash(BINARY ...) rules
		if [[ $rule =~ ^Bash\(([^\ \)]+) ]]; then
			local bin="${BASH_REMATCH[1]}"
			if is_blocklisted_binary "$bin"; then
				continue
			fi
		fi
		echo "$rule"
	done
}

RULES_FROM_LOG=$(jq -r '.rule // empty' "$LOG_FILE" |
	grep -E '^(Bash\(.*\)|Read|Write|Edit|MultiEdit|WebFetch(\(.*\))?|mcp__.*)$' |
	filter_rules |
	sort -u)

# --- Read existing allow rules from settings.json ---
EXISTING_RULES=""
if [[ -f $SETTINGS_FILE ]]; then
	EXISTING_RULES=$(jq -r '.permissions.allow[]? // empty' "$SETTINGS_FILE" 2>/dev/null | sort -u)
fi

# --- Compute new rules (in log but not in settings) ---
NEW_RULES=""
while IFS= read -r rule; do
	[[ -z $rule ]] && continue
	if ! echo "$EXISTING_RULES" | grep -qxF "$rule"; then
		NEW_RULES="${NEW_RULES}${rule}"$'\n'
	fi
done <<<"$RULES_FROM_LOG"
NEW_RULES=$(echo "$NEW_RULES" | sed '/^$/d' | sort -u)

# --- Combine all rules ---
ALL_RULES=$(printf '%s\n%s' "$EXISTING_RULES" "$RULES_FROM_LOG" | sed '/^$/d' | sort -u)

# expand_safe_direct_rules
#
# For each binary seen in the log that has tracked subcommands, emit
# Bash(binary subcmd *) for all safe subcommands (direct only, no indirection).
expand_safe_direct_rules() {
	local seen_binaries=""

	# Extract unique base_command binaries from new-format log entries
	local base_cmds
	base_cmds=$(jq -r 'select(.base_command != null and .base_command != "") | .base_command' "$LOG_FILE" 2>/dev/null | sort -u)

	# Collect unique binaries (first word of base_command)
	while IFS= read -r bc; do
		[[ -z $bc ]] && continue
		local bin="${bc%% *}"
		if has_subcommands "$bin"; then
			# Check if we've already seen this binary
			local already=0
			local sb
			for sb in $seen_binaries; do
				if [[ $sb == "$bin" ]]; then
					already=1
					break
				fi
			done
			if [[ $already -eq 0 ]]; then
				seen_binaries="${seen_binaries} ${bin}"
			fi
		fi
	done <<<"$base_cmds"

	# Also check old-format entries (rules like Bash(git *))
	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		# Match Bash(BINARY *) pattern
		if [[ $rule =~ ^Bash\(([a-zA-Z0-9_-]+)\ \*\)$ ]]; then
			local bin="${BASH_REMATCH[1]}"
			if has_subcommands "$bin"; then
				local already=0
				local sb
				for sb in $seen_binaries; do
					if [[ $sb == "$bin" ]]; then
						already=1
						break
					fi
				done
				if [[ $already -eq 0 ]]; then
					seen_binaries="${seen_binaries} ${bin}"
				fi
			fi
		fi
	done <<<"$RULES_FROM_LOG"

	# For each binary, emit safe subcommand rules + alternative flag forms
	for bin in $seen_binaries; do
		local safe_list
		safe_list=$(get_safe_subcommands "$bin")
		local alt_prefixes
		alt_prefixes=$(get_alt_rule_prefixes "$bin")
		local subcmd
		for subcmd in $safe_list; do
			echo "Bash(${bin} ${subcmd} *)"
			# Emit alternative forms (e.g. git -C * log *)
			local prefix
			for prefix in $alt_prefixes; do
				echo "Bash(${bin} ${prefix} * ${subcmd} *)"
			done
		done
	done
}

# collect_indirection_variants
#
# For each log entry that was observed with indirection, preserve that
# indirection variant as an additional rule.
collect_indirection_variants() {
	# Only process new-format entries with indirection_chain
	jq -r 'select(.indirection_chain != null and .indirection_chain != "" and .rule != null) | .rule' \
		"$LOG_FILE" 2>/dev/null | sort -u
}

# --- Helper: compute refined rules (used by --refine preview and --refine --apply) ---
compute_refined_rules() {
	# Find broad rules that could be refined
	BROAD_RULES=""
	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		if [[ $rule =~ ^Bash\(([a-zA-Z0-9_-]+)\ \*\)$ ]]; then
			_bin="${BASH_REMATCH[1]}"
			if has_subcommands "$_bin"; then
				BROAD_RULES="${BROAD_RULES}${rule}"$'\n'
			fi
		fi
	done <<<"$ALL_RULES"
	BROAD_RULES=$(echo "$BROAD_RULES" | sed '/^$/d')

	# Generate safe replacements
	SAFE_RULES=$(expand_safe_direct_rules | sort -u)

	# Collect observed non-safe subcommand rules from the log
	OBSERVED_RULES=""
	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		# Match Bash(BINARY SUBCMD *) pattern
		if [[ $rule =~ ^Bash\(([a-zA-Z0-9_-]+)\ ([a-zA-Z0-9_-]+)\ \*\)$ ]]; then
			_bin="${BASH_REMATCH[1]}"
			_subcmd="${BASH_REMATCH[2]}"
			if ! is_safe_subcommand "$_bin" "$_subcmd"; then
				OBSERVED_RULES="${OBSERVED_RULES}${rule}"$'\n'
			fi
		fi
	done <<<"$RULES_FROM_LOG"
	OBSERVED_RULES=$(echo "$OBSERVED_RULES" | sed '/^$/d' | sort -u)

	# Indirection variants from the log
	INDIRECTION_RULES=$(collect_indirection_variants)

	# Build refined rule set: start with current, remove broad, add fine-grained
	REFINED_RULES="$ALL_RULES"
	while IFS= read -r broad; do
		[[ -z $broad ]] && continue
		REFINED_RULES=$(echo "$REFINED_RULES" | grep -vxF "$broad" || true)
	done <<<"$BROAD_RULES"

	# Only include safe subcommand rules in the refined set.
	# Observed non-safe commands and indirection variants are shown
	# for informational purposes but require manual opt-in.
	REFINED_RULES=$(printf '%s\n%s' "$REFINED_RULES" "$SAFE_RULES" | sed '/^$/d' | sort -u)
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

	TEMP=$(mktemp)
	jq --argjson allow "$ALLOW_JSON" '
      .permissions //= {} |
      .permissions.allow = $allow
    ' "$SETTINGS_FILE" >"$TEMP"

	if jq empty "$TEMP" 2>/dev/null; then
		cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
		mv "$TEMP" "$SETTINGS_FILE"
		echo "Updated $SETTINGS_FILE ($label)"
		echo "Backup at ${SETTINGS_FILE}.bak"
	else
		echo "ERROR: Generated invalid JSON. Aborting."
		rm -f "$TEMP"
		exit 1
	fi
}

# --- Dispatch ---
if [[ $REFINE -eq 1 ]]; then
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

	if [[ -n $INDIRECTION_RULES ]]; then
		echo "Indirection variant rules (NOT included — add manually if needed):"
		# shellcheck disable=SC2001
		echo "$INDIRECTION_RULES" | sed 's/^/    /'
		echo ""
	fi

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

	*)
		echo "Usage: $0 [--preview|--apply|--print|--diff|--refine] [--apply]"
		exit 1
		;;
	esac
fi
