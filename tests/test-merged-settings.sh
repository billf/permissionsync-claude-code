#!/usr/bin/env bash
# test-permissionsync-settings.sh — tests for permissionsync-settings.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGED_SCRIPT="${SCRIPT_DIR}/../permissionsync-settings.sh"
ORIG_DIR="$(pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
trap 'cd "$ORIG_DIR"; rm -rf "$TMP_DIR"' EXIT

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

assert_contains() {
	local desc="$1" needle="$2" haystack="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if echo "$haystack" | grep -qF "$needle"; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected to contain: '${needle}'"
		echo "#   output: '${haystack}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_not_contains() {
	local desc="$1" needle="$2" haystack="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if ! echo "$haystack" | grep -qF "$needle"; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected NOT to contain: '${needle}'"
		echo "#   output: '${haystack}'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# ============================================================
# Setup: fake HOME with global settings, git repo with worktrees
# ============================================================

FAKE_HOME="${TMP_DIR}/home"
mkdir -p "${FAKE_HOME}/.claude"

cat >"${FAKE_HOME}/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git *)", "Bash(cargo check *)", "WebFetch(domain:docs.rs)"],
    "deny": ["Bash(rm *)"]
  }
}
EOF

# Git repo with worktrees
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

# main worktree: local settings
mkdir -p "$REPO_MAIN/.claude"
cat >"$REPO_MAIN/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(npm install *)", "Bash(git push *)"]
  }
}
EOF

# wt1: local settings with overlap and unique rule
mkdir -p "$REPO_WT1/.claude"
cat >"$REPO_WT1/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(npm install *)", "Bash(docker ps *)"]
  }
}
EOF

# JSONL log
LOG_FILE="${TMP_DIR}/test-log.jsonl"
jq -nc '{timestamp:"2024-01-01T00:00:00Z", tool:"Bash", rule:"Bash(kubectl get *)", cwd:"/tmp"}' >"$LOG_FILE"
jq -nc '{timestamp:"2024-01-01T00:01:00Z", tool:"Bash", rule:"Bash(pip list *)", cwd:"/tmp"}' >>"$LOG_FILE"

# ============================================================
# Test 1: Output is valid JSON
# ============================================================

cd "$REPO_MAIN"
out=$(HOME="$FAKE_HOME" bash "$MERGED_SCRIPT" 2>/dev/null)
TEST_NUM=$((TEST_NUM + 1))
if echo "$out" | jq empty 2>/dev/null; then
	echo "ok ${TEST_NUM} - output is valid JSON"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - output is valid JSON"
	echo "#   output: '${out}'"
	FAIL=$((FAIL + 1))
fi

# ============================================================
# Test 2: Output has .permissions.allow and .permissions.deny arrays
# ============================================================

allow_type=$(echo "$out" | jq -r '.permissions.allow | type')
deny_type=$(echo "$out" | jq -r '.permissions.deny | type')
assert_eq "has .permissions.allow array" "array" "$allow_type"
assert_eq "has .permissions.deny array" "array" "$deny_type"

# ============================================================
# Test 3: Global allow rules included
# ============================================================

assert_contains "global allow: git rule included" "Bash(git *)" "$out"
assert_contains "global allow: cargo check included" "Bash(cargo check *)" "$out"
assert_contains "global allow: WebFetch included" "WebFetch(domain:docs.rs)" "$out"

# ============================================================
# Test 4: Global deny rules preserved
# ============================================================

assert_contains "global deny: rm rule preserved" "Bash(rm *)" "$out"

# ============================================================
# Test 5: Worktree rules merged
# ============================================================

assert_contains "worktree: npm install merged" "Bash(npm install *)" "$out"
assert_contains "worktree: docker ps merged" "Bash(docker ps *)" "$out"
assert_contains "worktree: git push merged" "Bash(git push *)" "$out"

# ============================================================
# Test 6: Rules deduplicated (npm install appears in both worktrees)
# ============================================================

npm_count=$(echo "$out" | jq '[.permissions.allow[] | select(. == "Bash(npm install *)")] | length')
assert_eq "npm install deduplicated" "1" "$npm_count"

# ============================================================
# Test 7: Blocklisted binaries filtered
# ============================================================

# Add a worktree with a blocklisted binary rule
cat >"$REPO_WT1/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(npm install *)", "Bash(docker ps *)", "Bash(python *)"]
  }
}
EOF

out_filtered=$(HOME="$FAKE_HOME" bash "$MERGED_SCRIPT" 2>/dev/null)
assert_not_contains "blocklisted python filtered" "Bash(python *)" "$out_filtered"
# Restore wt1
cat >"$REPO_WT1/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(npm install *)", "Bash(docker ps *)"]
  }
}
EOF

# ============================================================
# Test 8: --refine replaces broad rules with safe-subcommand expansions
# ============================================================

refined_out=$(HOME="$FAKE_HOME" bash "$MERGED_SCRIPT" --refine 2>/dev/null)
# Bash(git *) is broad — should be replaced
assert_not_contains "--refine removes broad Bash(git *)" '"Bash(git *)"' "$refined_out"
# Should have safe subcommand expansions
assert_contains "--refine adds Bash(git status *)" "Bash(git status *)" "$refined_out"
assert_contains "--refine adds Bash(git log *)" "Bash(git log *)" "$refined_out"

# ============================================================
# Test 9: --refine preserves non-broad rules
# ============================================================

assert_contains "--refine preserves cargo check" "Bash(cargo check *)" "$refined_out"
assert_contains "--refine preserves WebFetch" "WebFetch(domain:docs.rs)" "$refined_out"
assert_contains "--refine preserves npm install" "Bash(npm install *)" "$refined_out"

# ============================================================
# Test 10: --from-log includes log rules
# ============================================================

log_out=$(HOME="$FAKE_HOME" CLAUDE_PERMISSION_LOG="$LOG_FILE" bash "$MERGED_SCRIPT" --from-log 2>/dev/null)
assert_contains "--from-log includes kubectl get" "Bash(kubectl get *)" "$log_out"
assert_contains "--from-log includes pip list" "Bash(pip list *)" "$log_out"

# ============================================================
# Test 11: --global-only skips worktree rules
# ============================================================

global_out=$(HOME="$FAKE_HOME" bash "$MERGED_SCRIPT" --global-only 2>/dev/null)
assert_contains "--global-only includes global git" "Bash(git *)" "$global_out"
assert_not_contains "--global-only skips worktree npm install" "Bash(npm install *)" "$global_out"
assert_not_contains "--global-only skips worktree docker ps" "Bash(docker ps *)" "$global_out"

# ============================================================
# Test 12: stderr is clean (stdout is pure JSON)
# ============================================================

stderr_out=$(HOME="$FAKE_HOME" bash "$MERGED_SCRIPT" 2>&1 1>/dev/null)
assert_eq "stderr is clean" "" "$stderr_out"

# ============================================================
# Test 13: Works outside git repo (fallback to global-only)
# ============================================================

NO_GIT_DIR="${TMP_DIR}/no-git"
mkdir -p "$NO_GIT_DIR"
cd "$NO_GIT_DIR"
no_git_out=$(HOME="$FAKE_HOME" bash "$MERGED_SCRIPT" 2>/dev/null)
TEST_NUM=$((TEST_NUM + 1))
if echo "$no_git_out" | jq empty 2>/dev/null; then
	echo "ok ${TEST_NUM} - works outside git repo (valid JSON)"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - works outside git repo (valid JSON)"
	echo "#   output: '${no_git_out}'"
	FAIL=$((FAIL + 1))
fi
assert_contains "outside git: has global rules" "Bash(git *)" "$no_git_out"

# ============================================================
# Test 14: Empty sources produce valid empty structure
# ============================================================

EMPTY_HOME="${TMP_DIR}/empty-home"
mkdir -p "${EMPTY_HOME}/.claude"
echo '{}' >"${EMPTY_HOME}/.claude/settings.json"

cd "$NO_GIT_DIR"
empty_out=$(HOME="$EMPTY_HOME" bash "$MERGED_SCRIPT" 2>/dev/null)
expected_empty='{"permissions":{"allow":[],"deny":[]}}'
actual_compact=$(echo "$empty_out" | jq -c .)
assert_eq "empty sources produce valid structure" "$expected_empty" "$actual_compact"

cd "$ORIG_DIR"

echo ""
echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"
if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
