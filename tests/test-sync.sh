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

assert_filtered "variable assignment in binary" 'Bash(TMP_DIR="$(mktemp *)'
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

echo ""
echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
