#!/usr/bin/env bash
# test-build-rule.sh — unit tests for build_rule_v2()
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../permissionsync-lib.sh
source "${SCRIPT_DIR}/../permissionsync-lib.sh"

PASS=0
FAIL=0
TEST_NUM=0

# assert_rule TOOL_NAME TOOL_INPUT_JSON EXPECTED_RULE [EXPECTED_BASE_CMD] [EXPECTED_IS_SAFE] [EXPECTED_CHAIN]
assert_rule() {
	local tool="$1" input="$2" expected_rule="$3"
	local expected_base="${4:-}" expected_safe="${5:-false}" expected_chain="${6:-}"
	TEST_NUM=$((TEST_NUM + 1))

	build_rule_v2 "$tool" "$input"

	local ok=1
	local details=""
	if [[ $RULE != "$expected_rule" ]]; then
		ok=0
		details="${details}#   rule: expected '${expected_rule}', got '${RULE}'"$'\n'
	fi
	if [[ -n $expected_base ]] && [[ $BASE_COMMAND != "$expected_base" ]]; then
		ok=0
		details="${details}#   base_command: expected '${expected_base}', got '${BASE_COMMAND}'"$'\n'
	fi
	if [[ $IS_SAFE != "$expected_safe" ]]; then
		ok=0
		details="${details}#   is_safe: expected '${expected_safe}', got '${IS_SAFE}'"$'\n'
	fi
	if [[ -n $expected_chain ]] && [[ $INDIRECTION_CHAIN != "$expected_chain" ]]; then
		ok=0
		details="${details}#   indirection_chain: expected '${expected_chain}', got '${INDIRECTION_CHAIN}'"$'\n'
	fi

	local desc
	desc="${tool} $(echo "$input" | jq -r '.command // .url // .file_path // "?"')"
	if [[ $ok -eq 1 ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo -n "$details"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# --- Bash: simple commands ---
assert_rule "Bash" '{"command":"git status"}' \
	"Bash(git status *)" "git status" "true" ""

assert_rule "Bash" '{"command":"git push origin main"}' \
	"Bash(git push *)" "git push" "false" ""

assert_rule "Bash" '{"command":"ls -la"}' \
	"Bash(ls *)" "ls" "false" ""

assert_rule "Bash" '{"command":"cargo check --workspace"}' \
	"Bash(cargo check *)" "cargo check" "true" ""

assert_rule "Bash" '{"command":"cargo publish"}' \
	"Bash(cargo publish *)" "cargo publish" "false" ""

# --- Bash: indirection ---
assert_rule "Bash" '{"command":"sudo git push origin main"}' \
	"Bash(git push *)" "git push" "false" "sudo"

assert_rule "Bash" '{"command":"env FOO=bar git status"}' \
	"Bash(git status *)" "git status" "true" "env"

assert_rule "Bash" '{"command":"xargs git log"}' \
	"Bash(git log *)" "git log" "true" "xargs"

assert_rule "Bash" '{"command":"bash -c '\''git diff'\''"}' \
	"Bash(git diff *)" "git diff" "true" "bash"

# --- Bash: no subcommand tracking for unknown binaries ---
assert_rule "Bash" '{"command":"python script.py"}' \
	"Bash(python *)" "python" "false" ""

# --- Bash: multiline commands (should use first line only) ---
assert_rule "Bash" "$(printf '{"command":"git commit -m msg\\nCo-Authored-By: test"}')" \
	"Bash(git commit *)" "git commit" "false" ""

# --- Bash: shell keywords should not become rules ---
# shellcheck disable=SC2016
assert_rule "Bash" '{"command":"for f in *.sh; do echo $f; done"}' \
	"Bash" "" "false" ""

assert_rule "Bash" '{"command":"if true; then echo yes; fi"}' \
	"Bash" "" "false" ""

# shellcheck disable=SC2016
assert_rule "Bash" '{"command":"while read -r line; do echo $line; done"}' \
	"Bash" "" "false" ""

# --- Bash: garbage/shell-syntax first word ---
assert_rule "Bash" '{"command":"){ echo foo; }"}' \
	"Bash" "" "false" ""

# --- Bash: empty command ---
assert_rule "Bash" '{"command":""}' \
	"Bash" "" "false" ""

assert_rule "Bash" '{}' \
	"Bash" "" "false" ""

# --- Non-Bash tools ---
assert_rule "Read" '{"file_path":"/tmp/foo.txt"}' \
	"Read" "" "false" ""

assert_rule "Write" '{"file_path":"/tmp/bar.txt"}' \
	"Write" "" "false" ""

assert_rule "WebFetch" '{"url":"https://example.com/page"}' \
	"WebFetch(domain:example.com)" "" "false" ""

assert_rule "WebFetch" '{}' \
	"WebFetch" "" "false" ""

assert_rule "mcp__my_server" '{}' \
	"mcp__my_server" "" "false" ""

assert_rule "SomeOtherTool" '{}' \
	"SomeOtherTool" "" "false" ""

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
