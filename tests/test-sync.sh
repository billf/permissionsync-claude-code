#!/usr/bin/env bash
# test-sync.sh — tests for filter_rules() and sync-permissions.sh pipeline
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../permissionsync-lib.sh
source "${SCRIPT_DIR}/../permissionsync-lib.sh"
# Source sync-permissions.sh functions by extracting filter_rules
# (sync-permissions.sh is a script, not just a library — we source the lib
# and redefine filter_rules inline to test it in isolation)

PASS=0
FAIL=0
TEST_NUM=0

# Redefine filter_rules exactly as in sync-permissions.sh
filter_rules() {
	while IFS= read -r rule; do
		[[ -z $rule ]] && continue
		if [[ $rule == Bash\(* ]]; then
			# Extract the binary from Bash(BINARY ...) rules
			if [[ $rule =~ ^Bash\(([^\ \)]+) ]]; then
				local bin="${BASH_REMATCH[1]}"
				# Reject shells/interpreters
				if is_blocklisted_binary "$bin"; then continue; fi
				# Reject shell keywords (for, if, while, etc.)
				if is_shell_keyword "$bin"; then continue; fi
				# Reject invalid binary names (variable assignments, metacharacters)
				if [[ ! $bin =~ ^[a-zA-Z0-9_.~/-]+$ ]]; then continue; fi
			else
				# Bash(...) but couldn't extract a valid binary — reject
				continue
			fi
		fi
		echo "$rule"
	done
}

assert_filtered() {
	local desc="$1" input="$2"
	TEST_NUM=$((TEST_NUM + 1))
	local result
	result=$(echo "$input" | filter_rules)
	if [[ -z $result ]]; then
		echo "ok ${TEST_NUM} - filtered: ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - should be filtered: ${desc}"
		echo "#   input:  '${input}'"
		echo "#   output: '${result}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_passes() {
	local desc="$1" input="$2"
	TEST_NUM=$((TEST_NUM + 1))
	local result
	result=$(echo "$input" | filter_rules)
	if [[ $result == "$input" ]]; then
		echo "ok ${TEST_NUM} - passes: ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - should pass through: ${desc}"
		echo "#   input:  '${input}'"
		echo "#   output: '${result}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_grep_excludes() {
	local desc="$1" input="$2"
	local grep_pattern='^(Bash\(.*\)|WebFetch(\(.*\))?|mcp__.*)$'
	TEST_NUM=$((TEST_NUM + 1))
	if ! echo "$input" | grep -qE "$grep_pattern"; then
		echo "ok ${TEST_NUM} - grep excludes: ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - grep should exclude: ${desc}"
		echo "#   input: '${input}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_grep_includes() {
	local desc="$1" input="$2"
	local grep_pattern='^(Bash\(.*\)|WebFetch(\(.*\))?|mcp__.*)$'
	TEST_NUM=$((TEST_NUM + 1))
	if echo "$input" | grep -qE "$grep_pattern"; then
		echo "ok ${TEST_NUM} - grep includes: ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - grep should include: ${desc}"
		echo "#   input: '${input}'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# ============================================================
# filter_rules: shell keywords should be rejected
# ============================================================

assert_filtered "shell keyword: for" 'Bash(for *)'
assert_filtered "shell keyword: if" 'Bash(if *)'
assert_filtered "shell keyword: while" 'Bash(while *)'
assert_filtered "shell keyword: case" 'Bash(case *)'

# ============================================================
# filter_rules: invalid binary names should be rejected
# ============================================================

# shellcheck disable=SC2016
assert_filtered "variable assignment in binary" 'Bash(TMP_DIR="$(mktemp *)'
# shellcheck disable=SC2016
assert_filtered "dollar sign in binary" 'Bash($(echo *)'
assert_filtered "equals sign in binary" 'Bash(FOO=bar *)'
assert_filtered "parenthesis in binary" 'Bash(){ *)'

# ============================================================
# filter_rules: blocklisted binaries should be rejected
# ============================================================

assert_filtered "blocklisted: python" 'Bash(python *)'
assert_filtered "blocklisted: bash" 'Bash(bash *)'
assert_filtered "blocklisted: node" 'Bash(node *)'

# ============================================================
# filter_rules: valid rules should pass through
# ============================================================

assert_passes "valid: git status" 'Bash(git status *)'
assert_passes "valid: cargo check" 'Bash(cargo check *)'
assert_passes "valid: gh pr" 'Bash(gh pr *)'
assert_passes "valid: cat" 'Bash(cat *)'
assert_passes "valid: ls" 'Bash(ls *)'

# Non-Bash rules pass through filter_rules unchanged
assert_passes "non-Bash: WebFetch domain" 'WebFetch(domain:example.com)'
assert_passes "non-Bash: mcp tool" 'mcp__my_server__tool'
assert_passes "non-Bash: bare WebFetch" 'WebFetch'

# ============================================================
# grep pattern: bare file-tool names should be excluded
# ============================================================

assert_grep_excludes "bare Read" 'Read'
assert_grep_excludes "bare Write" 'Write'
assert_grep_excludes "bare Edit" 'Edit'
assert_grep_excludes "bare MultiEdit" 'MultiEdit'

# ============================================================
# grep pattern: valid rules should be included
# ============================================================

assert_grep_includes "Bash rule" 'Bash(git status *)'
assert_grep_includes "WebFetch with domain" 'WebFetch(domain:example.com)'
assert_grep_includes "bare WebFetch" 'WebFetch'
assert_grep_includes "mcp tool" 'mcp__server__tool'

# ============================================================
# Full pipeline test: crafted JSONL → filter_rules → output
# ============================================================

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Create a crafted JSONL log with problematic entries
LOG_FILE="${TMP_DIR}/test.jsonl"
cat >"$LOG_FILE" <<'JSONL'
{"rule":"Bash(for *)","tool":"Bash","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"Bash(TMP_DIR=\"$(mktemp *)","tool":"Bash","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"Read","tool":"Read","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"Edit","tool":"Edit","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"Write","tool":"Write","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"MultiEdit","tool":"MultiEdit","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"Bash(python *)","tool":"Bash","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"Bash(git status *)","tool":"Bash","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"Bash(gh pr *)","tool":"Bash","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"WebFetch(domain:example.com)","tool":"WebFetch","timestamp":"2024-01-01T00:00:00Z"}
{"rule":"mcp__server__tool","tool":"mcp__server__tool","timestamp":"2024-01-01T00:00:00Z"}
JSONL

PIPELINE_OUTPUT=$(jq -r '.rule // empty' "$LOG_FILE" |
	grep -E '^(Bash\(.*\)|WebFetch(\(.*\))?|mcp__.*)$' |
	filter_rules |
	sort -u)

TEST_NUM=$((TEST_NUM + 1))
if echo "$PIPELINE_OUTPUT" | grep -qF 'Bash(git status *)'; then
	echo "ok ${TEST_NUM} - pipeline: valid git rule passes"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: valid git rule should pass"
	echo "#   output: '${PIPELINE_OUTPUT}'"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if echo "$PIPELINE_OUTPUT" | grep -qF 'Bash(gh pr *)'; then
	echo "ok ${TEST_NUM} - pipeline: valid gh rule passes"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: valid gh rule should pass"
	echo "#   output: '${PIPELINE_OUTPUT}'"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if echo "$PIPELINE_OUTPUT" | grep -qF 'WebFetch(domain:example.com)'; then
	echo "ok ${TEST_NUM} - pipeline: WebFetch rule passes"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: WebFetch rule should pass"
	echo "#   output: '${PIPELINE_OUTPUT}'"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if echo "$PIPELINE_OUTPUT" | grep -qF 'mcp__server__tool'; then
	echo "ok ${TEST_NUM} - pipeline: mcp rule passes"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: mcp rule should pass"
	echo "#   output: '${PIPELINE_OUTPUT}'"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if ! echo "$PIPELINE_OUTPUT" | grep -qF 'Bash(for *)'; then
	echo "ok ${TEST_NUM} - pipeline: shell keyword filtered"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: shell keyword should be filtered"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if ! echo "$PIPELINE_OUTPUT" | grep -qF 'TMP_DIR'; then
	echo "ok ${TEST_NUM} - pipeline: invalid binary filtered"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: invalid binary should be filtered"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if ! echo "$PIPELINE_OUTPUT" | grep -qxF 'Read'; then
	echo "ok ${TEST_NUM} - pipeline: bare Read excluded"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: bare Read should be excluded"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if ! echo "$PIPELINE_OUTPUT" | grep -qxF 'Edit'; then
	echo "ok ${TEST_NUM} - pipeline: bare Edit excluded"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: bare Edit should be excluded"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if ! echo "$PIPELINE_OUTPUT" | grep -qF 'Bash(python *)'; then
	echo "ok ${TEST_NUM} - pipeline: blocklisted binary filtered"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: blocklisted binary should be filtered"
	FAIL=$((FAIL + 1))
fi

# Verify exact rule count in output (should be 4: git, gh, WebFetch, mcp)
TEST_NUM=$((TEST_NUM + 1))
RULE_COUNT=$(echo "$PIPELINE_OUTPUT" | grep -c . || true)
if [[ $RULE_COUNT -eq 4 ]]; then
	echo "ok ${TEST_NUM} - pipeline: exactly 4 rules in output"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - pipeline: expected 4 rules, got ${RULE_COUNT}"
	echo "#   output: '${PIPELINE_OUTPUT}'"
	FAIL=$((FAIL + 1))
fi

# ============================================================
# expand_safe_direct_rules: compound-key expansion
# ============================================================

# Source the full expand_safe_direct_rules function
expand_safe_direct_rules() {
	local seen_binaries
	seen_binaries=$(
		{
			jq -r 'select(.base_command != null and .base_command != "") | .base_command | split(" ")[0]' \
				"$LOG_FILE" 2>/dev/null
			echo "$RULES_FROM_LOG" | sed -n 's/^Bash(\([a-zA-Z0-9_-]*\) \*)/\1/p'
		} | sort -u
	)

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
				local parent="${word%%:*}"
				local sub="${word#*:}"
				echo "Bash(${bin} ${parent} ${sub} *)"
			else
				echo "Bash(${bin} ${word} *)"
				local prefix
				for prefix in $alt_prefixes; do
					echo "Bash(${bin} ${prefix} * ${word} *)"
				done
			fi
		done
	done
}

# Create log with gh entries to test expansion
GH_LOG="${TMP_DIR}/gh-test.jsonl"
cat >"$GH_LOG" <<'JSONL'
{"rule":"Bash(gh pr *)","base_command":"gh pr","tool":"Bash","timestamp":"2024-01-01T00:00:00Z"}
JSONL

LOG_FILE="$GH_LOG"
RULES_FROM_LOG="Bash(gh pr *)"

EXPANSION=$(expand_safe_direct_rules | sort -u)

TEST_NUM=$((TEST_NUM + 1))
if echo "$EXPANSION" | grep -qF 'Bash(gh pr list *)'; then
	echo "ok ${TEST_NUM} - expansion: compound key pr:list → Bash(gh pr list *)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - expansion: should include Bash(gh pr list *)"
	echo "#   output: '${EXPANSION}'"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if echo "$EXPANSION" | grep -qF 'Bash(gh pr view *)'; then
	echo "ok ${TEST_NUM} - expansion: compound key pr:view → Bash(gh pr view *)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - expansion: should include Bash(gh pr view *)"
	echo "#   output: '${EXPANSION}'"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if echo "$EXPANSION" | grep -qF 'Bash(gh status *)'; then
	echo "ok ${TEST_NUM} - expansion: standalone gh status emitted"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - expansion: should include Bash(gh status *)"
	echo "#   output: '${EXPANSION}'"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if echo "$EXPANSION" | grep -qF 'Bash(gh browse *)'; then
	echo "ok ${TEST_NUM} - expansion: standalone gh browse emitted"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - expansion: should include Bash(gh browse *)"
	echo "#   output: '${EXPANSION}'"
	FAIL=$((FAIL + 1))
fi

# ============================================================
# --init-base: preview and apply modes
# ============================================================

# Create a fake base-settings.json
BASE_DIR="${TMP_DIR}/share/permissionsync-cc"
mkdir -p "$BASE_DIR"
cat >"${BASE_DIR}/base-settings.json" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(git status *)",
      "Bash(gh pr list *)",
      "Bash(gh pr view *)"
    ],
    "deny": [
      "Read(~/.gitconfig)"
    ]
  }
}
JSON

# Create a fake settings.json with one existing rule
FAKE_SETTINGS="${TMP_DIR}/settings.json"
cat >"$FAKE_SETTINGS" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(git status *)"
    ]
  }
}
JSON

# Test --init-base preview
# shellcheck disable=SC2034
SETTINGS_FILE="$FAKE_SETTINGS"
PERMISSIONSYNC_SHARE_DIR="$BASE_DIR"
export PERMISSIONSYNC_SHARE_DIR

# Source the find_base_settings function
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
	return 1
}

BASE_SETTINGS=$(find_base_settings)
TEST_NUM=$((TEST_NUM + 1))
if [[ -n $BASE_SETTINGS ]] && [[ -f $BASE_SETTINGS ]]; then
	echo "ok ${TEST_NUM} - init-base: found base-settings.json"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - init-base: should find base-settings.json"
	FAIL=$((FAIL + 1))
fi

# Compute what would be merged
BASE_ALLOW=$(jq -r '.permissions.allow[]? // empty' "$BASE_SETTINGS" | sort -u)
EXISTING_ALLOW=$(jq -r '.permissions.allow[]? // empty' "$FAKE_SETTINGS" | sort -u)
NEW_BASE_ALLOW=$(comm -23 <(echo "$BASE_ALLOW" | sed '/^$/d') <(echo "$EXISTING_ALLOW" | sed '/^$/d'))

TEST_NUM=$((TEST_NUM + 1))
if echo "$NEW_BASE_ALLOW" | grep -qF 'Bash(gh pr list *)'; then
	echo "ok ${TEST_NUM} - init-base: gh pr list would be added"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - init-base: gh pr list should be new"
	echo "#   new_allow: '${NEW_BASE_ALLOW}'"
	FAIL=$((FAIL + 1))
fi

TEST_NUM=$((TEST_NUM + 1))
if ! echo "$NEW_BASE_ALLOW" | grep -qF 'Bash(git status *)'; then
	echo "ok ${TEST_NUM} - init-base: git status already exists, not new"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - init-base: git status should not be new (already exists)"
	FAIL=$((FAIL + 1))
fi

# Test deny rules
BASE_DENY=$(jq -r '.permissions.deny[]? // empty' "$BASE_SETTINGS" | sort -u)
TEST_NUM=$((TEST_NUM + 1))
if echo "$BASE_DENY" | grep -qF 'Read(~/.gitconfig)'; then
	echo "ok ${TEST_NUM} - init-base: deny rules present"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - init-base: should have deny rules"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
