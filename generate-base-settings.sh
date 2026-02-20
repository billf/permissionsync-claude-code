#!/usr/bin/env bash
# generate-base-settings.sh — build-time: merge claude-baseline readonly tiers
#
# Usage: generate-base-settings.sh <claude-baseline-src> <output-path>
#
# Reads index.json from claude-baseline, finds stacks with a "readonly" tier,
# merges their allow/deny arrays, normalizes colon format to space format,
# validates against blocklist, and writes the result as JSON.

set -euo pipefail

BASELINE_SRC="$1"
OUTPUT_PATH="$2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=permissionsync-config.sh
source "${SCRIPT_DIR}/permissionsync-config.sh"

# Collect stacks that have a "readonly" tier (excluding "bash" for security —
# it contains Bash(find *) which enables find -exec arbitrary code execution)
READONLY_STACKS=$(jq -r '
  .stacks | to_entries[]
  | select(.value.tiers | index("readonly"))
  | select(.key != "bash")
  | .key
' "${BASELINE_SRC}/index.json")

if [[ -z $READONLY_STACKS ]]; then
	echo "ERROR: No readonly stacks found in ${BASELINE_SRC}/index.json" >&2
	exit 1
fi

# Merge all allow and deny rules from readonly settings files
ALLOW_LINES=""
DENY_LINES=""

for stack in $READONLY_STACKS; do
	settings_file="${BASELINE_SRC}/${stack}/settings.readonly.json"
	if [[ ! -f $settings_file ]]; then
		echo "WARNING: Missing ${settings_file}, skipping" >&2
		continue
	fi

	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		ALLOW_LINES="${ALLOW_LINES}${rule}"$'\n'
	done < <(jq -r '.permissions.allow[]? // empty' "$settings_file")

	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		DENY_LINES="${DENY_LINES}${rule}"$'\n'
	done < <(jq -r '.permissions.deny[]? // empty' "$settings_file")
done

# Normalize colon format to space format: Bash(cmd:*) → Bash(cmd *)
# Filter against blocklist and remove unsafe write operations
filter_and_normalize() {
	while IFS= read -r rule; do
		[[ -z $rule ]] && continue

		# Normalize deprecated colon format: Bash(cmd:*) → Bash(cmd *)
		# shellcheck disable=SC2001
		rule=$(echo "$rule" | sed 's/:\*)/\ \*)/g')

		# Validate Bash rules
		if [[ $rule == Bash\(* ]]; then
			if [[ $rule =~ ^Bash\(([^\ \)]+) ]]; then
				local bin="${BASH_REMATCH[1]}"
				if is_blocklisted_binary "$bin"; then
					echo "WARNING: Skipping blocklisted rule: $rule" >&2
					continue
				fi
			fi
			# Skip gh repo clone — write operation
			if [[ $rule == "Bash(gh repo clone *)" ]]; then
				echo "WARNING: Skipping write operation: $rule" >&2
				continue
			fi
		fi

		echo "$rule"
	done
}

FILTERED_ALLOW=$(echo "$ALLOW_LINES" | filter_and_normalize | sort -u)
FILTERED_DENY=$(echo "$DENY_LINES" | sed 's/:\*)/\ \*)/g' | sort -u)

# Write JSON output
ALLOW_JSON=$(echo "$FILTERED_ALLOW" | jq -R -s 'split("\n") | map(select(length > 0))')
DENY_JSON=$(echo "$FILTERED_DENY" | jq -R -s 'split("\n") | map(select(length > 0))')

jq -n --argjson allow "$ALLOW_JSON" --argjson deny "$DENY_JSON" '{
  permissions: {
    allow: $allow,
    deny: $deny
  }
}' >"$OUTPUT_PATH"

ALLOW_COUNT=$(echo "$ALLOW_JSON" | jq 'length')
DENY_COUNT=$(echo "$DENY_JSON" | jq 'length')
echo "Generated $OUTPUT_PATH with ${ALLOW_COUNT} allow rules and ${DENY_COUNT} deny rules"
