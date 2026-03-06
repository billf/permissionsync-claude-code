#!/usr/bin/env bash
# test-is-valid-rule.sh — tests for is_valid_rule() structural validator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/permissionsync-lib.sh
source "${SCRIPT_DIR}/../lib/permissionsync-lib.sh"

PASS=0
FAIL=0
TEST_NUM=0

assert_valid() {
	local desc="$1" input="$2"
	TEST_NUM=$((TEST_NUM + 1))
	if is_valid_rule "$input"; then
		echo "ok ${TEST_NUM} - valid: ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - should be valid: ${desc}"
		echo "#   input: '${input}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_invalid() {
	local desc="$1" input="$2"
	TEST_NUM=$((TEST_NUM + 1))
	if ! is_valid_rule "$input"; then
		echo "ok ${TEST_NUM} - invalid: ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - should be invalid: ${desc}"
		echo "#   input: '${input}'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# ============================================================
# Valid rules — all formats produced by build_rule_v2
# ============================================================

assert_valid "Bash(git status *)" 'Bash(git status *)'
assert_valid "Bash(cargo check *)" 'Bash(cargo check *)'
assert_valid "Bash(gh pr list *)" 'Bash(gh pr list *)'
assert_valid "Bash(cat *)" 'Bash(cat *)'
assert_valid "Bash(ls *)" 'Bash(ls *)'
assert_valid "bare Bash" 'Bash'
assert_valid "WebFetch(domain:example.com)" 'WebFetch(domain:example.com)'
assert_valid "WebFetch(domain:arxiv.org)" 'WebFetch(domain:arxiv.org)'
assert_valid "bare WebFetch" 'WebFetch'
assert_valid "mcp tool" 'mcp__server__tool'
assert_valid "mcp tool with underscores" 'mcp__my_server__my_tool'
assert_valid "mcp tool single segment" 'mcp__tool'
assert_valid "Read" 'Read'
assert_valid "Write" 'Write'
assert_valid "Edit" 'Edit'
assert_valid "MultiEdit" 'MultiEdit'
assert_valid "Glob" 'Glob'
assert_valid "Grep" 'Grep'

# ============================================================
# Invalid strings — commit message fragments and garbage
# ============================================================

assert_invalid "commit msg: zerocopy derives" '- Add zerocopy derives to MarketState, ValidatorAction, VoteType, VoteDecision'
assert_invalid "commit msg: AllowanceUpdate" '- AllowanceUpdate, AllowanceRevoke, MarketStatusUpdate, ValidatorUpdate'
assert_invalid "commit msg: previous commit" '- MarketCreated already done in previous commit'
assert_invalid "commit msg: consensus.rs" '- OrderProposal, OrderVote, OrderCommit, OrderPrepare in consensus.rs:'
assert_invalid "commit msg: pad0" '- Update all struct literal constructions with _pad0 initializers'
assert_invalid "commit msg: linear ticket" '[BAC-217] add MockGatewayClient for testing'
assert_invalid "escaped paren" '\)")'
assert_invalid "commit msg: call recording" 'and call recording. Enables unit testing of handlers without real RPC connections.'
assert_invalid "co-authored-by" 'Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>'
assert_invalid "MockGatewayClient" 'MockGatewayClient implements GatewayClient with configurable return values'
assert_invalid "EOF literal" 'EOF'
assert_invalid "empty string" ''
assert_invalid "plain text" 'hello world'
assert_invalid "path" '/bin/bash'
assert_invalid "fix prefix" 'fix: update dependencies'
assert_invalid "markdown header" '## Summary'
assert_invalid "mcp with spaces" 'mcp__server tool'
assert_invalid "mcp bare prefix" 'mcp__'
assert_invalid "mcp with hyphen" 'mcp__my-server__tool'

# Bash rule with embedded newline
NEWLINE_RULE=$'Bash(git\nevil)'
assert_invalid "Bash with embedded newline" "$NEWLINE_RULE"

# Bash rule with embedded CR
CR_RULE=$'Bash(git\revil)'
assert_invalid "Bash with embedded CR" "$CR_RULE"

# ============================================================
# filter_rules now rejects garbage via is_valid_rule
# ============================================================

assert_filter_rejects() {
	local desc="$1" input="$2"
	TEST_NUM=$((TEST_NUM + 1))
	local result
	result=$(echo "$input" | filter_rules)
	if [[ -z $result ]]; then
		echo "ok ${TEST_NUM} - filter_rules rejects: ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - filter_rules should reject: ${desc}"
		echo "#   input:  '${input}'"
		echo "#   output: '${result}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_filter_rejects "commit msg via filter_rules" '- Add zerocopy derives to MarketState'
assert_filter_rejects "co-authored-by via filter_rules" 'Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>'
assert_filter_rejects "EOF via filter_rules" 'EOF'
assert_filter_rejects "linear ticket via filter_rules" '[BAC-217] add MockGatewayClient for testing'

echo ""
echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
