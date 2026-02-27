#!/usr/bin/env bash
# test-log-confirmed.sh — unit tests for log-confirmed.sh (PostToolUse hook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
BASE_LOG="${TMP_DIR}/permission-approvals.jsonl"
CONFIRMED_LOG="${TMP_DIR}/confirmed-approvals.jsonl"
trap 'rm -rf "$TMP_DIR"' EXIT

run_hook() {
	local tool_name="$1" tool_input_json="$2"
	local input
	input=$(jq -nc \
		--arg tool "$tool_name" \
		--argjson input "$tool_input_json" \
		--arg cwd "/tmp/repo" \
		--arg session "sess-test" \
		'{tool_name: $tool, tool_input: $input, cwd: $cwd, session_id: $session}')
	CLAUDE_PERMISSION_LOG="$BASE_LOG" \
		bash "${SCRIPT_DIR}/../log-confirmed.sh" <<<"$input"
}

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if [[ $expected == "$actual" ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected: '${expected}'"
		echo "#   actual:   '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# --- Test 1: Bash tool appends to confirmed log ---
run_hook "Bash" '{"command":"git status --short"}'

lines=$(wc -l <"$CONFIRMED_LOG" | tr -d ' ')
assert_eq "Bash tool appends one record" "1" "$lines"

# --- Test 2: Record has expected fields ---
rule=$(jq -r '.rule' "$CONFIRMED_LOG")
assert_eq "rule field set correctly" "Bash(git status *)" "$rule"

tool=$(jq -r '.tool' "$CONFIRMED_LOG")
assert_eq "tool field set correctly" "Bash" "$tool"

is_safe=$(jq -r '.is_safe' "$CONFIRMED_LOG")
assert_eq "is_safe field set correctly" "true" "$is_safe"

cwd=$(jq -r '.cwd' "$CONFIRMED_LOG")
assert_eq "cwd field set correctly" "/tmp/repo" "$cwd"

session=$(jq -r '.session_id' "$CONFIRMED_LOG")
assert_eq "session_id field set correctly" "sess-test" "$session"

ts=$(jq -r '.timestamp' "$CONFIRMED_LOG")
TEST_NUM=$((TEST_NUM + 1))
if [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
	echo "ok ${TEST_NUM} - timestamp is ISO 8601"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - timestamp should be ISO 8601, got: '$ts'"
	FAIL=$((FAIL + 1))
fi

# --- Test 3: Multiple tool invocations accumulate ---
run_hook "Bash" '{"command":"cargo check --workspace"}'
run_hook "Read" '{"file_path":"/tmp/foo.txt"}'

lines2=$(wc -l <"$CONFIRMED_LOG" | tr -d ' ')
assert_eq "Three tool invocations produce three records" "3" "$lines2"

# --- Test 4: Read tool produces correct rule ---
read_rule=$(jq -r 'select(.tool == "Read") | .rule' "$CONFIRMED_LOG")
assert_eq "Read tool rule is 'Read'" "Read" "$read_rule"

# --- Test 5: WebFetch tool produces domain-scoped rule ---
run_hook "WebFetch" '{"url":"https://docs.example.com/api"}'
webfetch_rule=$(jq -r 'select(.tool == "WebFetch") | .rule' "$CONFIRMED_LOG")
assert_eq "WebFetch rule includes domain" "WebFetch(domain:docs.example.com)" "$webfetch_rule"

# --- Test 6: Confirmed log path uses same dir as base log ---
# Confirmed log should be in same dir as base log, not the default ~/.claude/
assert_eq "confirmed log path uses base log directory" \
	"$(dirname "$BASE_LOG")" "$(dirname "$CONFIRMED_LOG")"

# --- Test 7: Empty tool_name falls through silently ---
lines_before=$(wc -l <"$CONFIRMED_LOG" | tr -d ' ')
empty_input='{"tool_name":"","tool_input":{},"cwd":"/tmp","session_id":""}'
CLAUDE_PERMISSION_LOG="$BASE_LOG" \
	bash "${SCRIPT_DIR}/../log-confirmed.sh" <<<"$empty_input"
lines_after=$(wc -l <"$CONFIRMED_LOG" | tr -d ' ')
assert_eq "empty tool_name: no record appended" "$lines_before" "$lines_after"

# --- Test 8: Unsafe command still gets logged (just IS_SAFE=false) ---
run_hook "Bash" '{"command":"git push origin main"}'
unsafe_rule=$(jq -r 'select(.rule == "Bash(git push *)") | .rule' "$CONFIRMED_LOG")
assert_eq "unsafe command still logged" "Bash(git push *)" "$unsafe_rule"
unsafe_safe=$(jq -r 'select(.rule == "Bash(git push *)") | .is_safe' "$CONFIRMED_LOG")
assert_eq "unsafe command has is_safe=false" "false" "$unsafe_safe"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
