#!/usr/bin/env bash
# test-worktree-auto.sh — tests for sibling worktree auto-approve in log-permission-auto.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORIG_DIR="$(pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
# Resolve to canonical path (macOS /var → /private/var)
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
LOG_FILE="${TMP_DIR}/permission-approvals.jsonl"
trap 'cd "$ORIG_DIR"; rm -rf "$TMP_DIR"' EXIT

assert_behavior() {
	local desc="$1" expected="$2" output="$3"
	TEST_NUM=$((TEST_NUM + 1))

	local actual=""
	if [[ -n $output ]]; then
		actual=$(jq -r '.hookSpecificOutput.decision.behavior // empty' <<<"$output")
	fi

	if [[ $actual == "$expected" ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected behavior: '${expected}'"
		echo "#   got behavior:      '${actual}'"
		echo "#   raw output:        '${output}'"
		FAIL=$((FAIL + 1))
	fi
}

run_hook() {
	local command="$1"
	local worktree_mode="${2:-0}"
	local auto_mode="${3:-1}"
	local cwd="${4:-$TMP_DIR}"
	local input
	input=$(jq -nc --arg command "$command" --arg cwd "$cwd" \
		'{tool_name:"Bash", tool_input:{command:$command}, cwd:$cwd}')
	CLAUDE_PERMISSION_LOG="$LOG_FILE" \
		CLAUDE_PERMISSION_AUTO="$auto_mode" \
		CLAUDE_PERMISSION_WORKTREE="$worktree_mode" \
		bash "${SCRIPT_DIR}/../log-permission-auto.sh" <<<"$input"
}

echo "TAP version 13"

# ============================================================
# Setup: Create a git repo with worktrees
# ============================================================

REPO_MAIN="${TMP_DIR}/repo-main"
mkdir -p "$REPO_MAIN"
git -C "$REPO_MAIN" init -b main >/dev/null 2>&1
git -C "$REPO_MAIN" config user.email "test@test.com"
git -C "$REPO_MAIN" config user.name "Test"
echo "hello" >"$REPO_MAIN/file.txt"
git -C "$REPO_MAIN" add file.txt
git -C "$REPO_MAIN" commit -m "init" >/dev/null 2>&1

REPO_WT1="${TMP_DIR}/repo-wt1"
git -C "$REPO_MAIN" worktree add "$REPO_WT1" -b wt1 >/dev/null 2>&1

# Add settings.local.json to wt1 with some rules
mkdir -p "$REPO_WT1/.claude"
cat >"$REPO_WT1/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git push *)", "Bash(cargo build *)"]
  }
}
EOF

# Standalone repo (no worktrees)
REPO_STANDALONE="${TMP_DIR}/repo-standalone"
mkdir -p "$REPO_STANDALONE"
git -C "$REPO_STANDALONE" init -b main >/dev/null 2>&1
git -C "$REPO_STANDALONE" config user.email "test@test.com"
git -C "$REPO_STANDALONE" config user.name "Test"
echo "alone" >"$REPO_STANDALONE/file.txt"
git -C "$REPO_STANDALONE" add file.txt
git -C "$REPO_STANDALONE" commit -m "init" >/dev/null 2>&1

# Clear log between tests
reset_log() { rm -f "$LOG_FILE"; }

# ============================================================
# Tests
# ============================================================

# Test 1: WORKTREE_MODE off → sibling rules NOT checked (unsafe command not auto-approved)
reset_log
cd "$REPO_MAIN"
out=$(run_hook "git push origin main" 0 1 "$REPO_MAIN")
assert_behavior "worktree mode off: unsafe first-seen command is not auto-approved" "" "$out"

# Test 2: WORKTREE_MODE on + rule matches sibling → auto-approved
reset_log
cd "$REPO_MAIN"
out=$(run_hook "git push origin main" 1 1 "$REPO_MAIN")
assert_behavior "worktree mode on: matching sibling rule auto-approved" "allow" "$out"

# Test 3: WORKTREE_MODE on + no match → falls through (not auto-approved on first see)
reset_log
cd "$REPO_MAIN"
out=$(run_hook "npm install" 1 1 "$REPO_MAIN")
assert_behavior "worktree mode on: non-matching rule falls through" "" "$out"

# Test 4: WORKTREE_MODE on + not a worktree repo → falls through
reset_log
cd "$REPO_STANDALONE"
out=$(run_hook "git push origin main" 1 1 "$REPO_STANDALONE")
assert_behavior "worktree mode on + standalone repo: falls through" "" "$out"

# Test 5: Exact match only — partial match should NOT auto-approve
# wt1 has "Bash(git push *)" but we request "git pushx" which gives "Bash(git pushx *)"
reset_log
cd "$REPO_MAIN"
out=$(run_hook "git pushx origin" 1 1 "$REPO_MAIN")
assert_behavior "worktree mode: no partial match" "" "$out"

# Test 6: Safe subcommand still auto-approves regardless of worktree mode
reset_log
cd "$REPO_MAIN"
out=$(run_hook "git status" 1 1 "$REPO_MAIN")
assert_behavior "safe subcommand still auto-approved with worktree mode" "allow" "$out"

# Test 7: Worktree auto-approve takes precedence over auto-mode log check
# (The command should be approved via worktree even if not in the log)
reset_log
cd "$REPO_MAIN"
out=$(run_hook "cargo build --release" 1 1 "$REPO_MAIN")
assert_behavior "worktree auto-approve works even without log history" "allow" "$out"

cd "$ORIG_DIR"

echo ""
echo "1..${TEST_NUM}"
echo "# pass ${PASS}/${TEST_NUM}"
if [[ $FAIL -gt 0 ]]; then
	echo "# FAIL ${FAIL}"
	exit 1
fi
