#!/usr/bin/env bash
# test-worktree-sync.sh — tests for worktree-sync.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/../worktree-sync.sh"
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

echo "TAP version 13"

# ============================================================
# Setup: Create a git repo with worktrees and settings
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

REPO_WT2="${TMP_DIR}/repo-wt2"
git -C "$REPO_MAIN" worktree add "$REPO_WT2" -b wt2 >/dev/null 2>&1

# main: has git and cargo rules
mkdir -p "$REPO_MAIN/.claude"
cat >"$REPO_MAIN/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git push *)", "Bash(cargo build *)"]
  }
}
EOF

# wt1: has git and npm rules (git overlaps with main)
mkdir -p "$REPO_WT1/.claude"
cat >"$REPO_WT1/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git push *)", "Bash(npm install *)"]
  }
}
EOF

# wt2: no settings file initially

# Standalone repo (no worktrees)
REPO_STANDALONE="${TMP_DIR}/repo-standalone"
mkdir -p "$REPO_STANDALONE"
git -C "$REPO_STANDALONE" init -b main >/dev/null 2>&1
git -C "$REPO_STANDALONE" config user.email "test@test.com"
git -C "$REPO_STANDALONE" config user.name "Test"
echo "alone" >"$REPO_STANDALONE/file.txt"
git -C "$REPO_STANDALONE" add file.txt
git -C "$REPO_STANDALONE" commit -m "init" >/dev/null 2>&1

# ============================================================
# Test: Preview shows aggregated rules
# ============================================================

cd "$REPO_MAIN"
out=$(bash "$SYNC_SCRIPT" --preview 2>&1)
assert_contains "preview shows cargo rule" "Bash(cargo build *)" "$out"
assert_contains "preview shows npm rule" "Bash(npm install *)" "$out"
assert_contains "preview shows git rule" "Bash(git push *)" "$out"
assert_contains "preview mentions worktree count" "3" "$out"

# ============================================================
# Test: --report shows frequency counts
# ============================================================

out=$(bash "$SYNC_SCRIPT" --report 2>&1)
assert_contains "report contains git push" "Bash(git push *)" "$out"
# git push appears in 2 worktrees (main and wt1)
assert_contains "report shows frequency count for git push" "2" "$out"

# ============================================================
# Test: --apply writes to current worktree
# ============================================================

# From wt2 (no settings yet), apply aggregated rules
cd "$REPO_WT2"
bash "$SYNC_SCRIPT" --apply >/dev/null 2>&1

wt2_rules=$(jq -r '.permissions.allow[]' "$REPO_WT2/.claude/settings.local.json" | sort)
has_cargo=$(echo "$wt2_rules" | grep -c "Bash(cargo build \*)" || true)
has_npm=$(echo "$wt2_rules" | grep -c "Bash(npm install \*)" || true)
has_git=$(echo "$wt2_rules" | grep -c "Bash(git push \*)" || true)
assert_eq "--apply: wt2 now has cargo rule" "1" "$has_cargo"
assert_eq "--apply: wt2 now has npm rule" "1" "$has_npm"
assert_eq "--apply: wt2 now has git rule" "1" "$has_git"

# ============================================================
# Test: Idempotent — running --apply twice produces same result
# ============================================================

# Capture state before second run
before=$(jq -S '.permissions.allow' "$REPO_WT2/.claude/settings.local.json")
cd "$REPO_WT2"
out=$(bash "$SYNC_SCRIPT" --apply 2>&1)
after=$(jq -S '.permissions.allow' "$REPO_WT2/.claude/settings.local.json")
assert_eq "--apply is idempotent" "$before" "$after"
assert_contains "--apply second run says in sync" "Already in sync" "$out"

# ============================================================
# Test: --apply-all writes to all worktrees
# ============================================================

# Remove wt2 settings to reset
rm -f "$REPO_WT2/.claude/settings.local.json"

cd "$REPO_MAIN"
bash "$SYNC_SCRIPT" --apply-all >/dev/null 2>&1

# All three should now have all three rules
for repo in "$REPO_MAIN" "$REPO_WT1" "$REPO_WT2"; do
	count=$(jq '[.permissions.allow[]] | length' "${repo}/.claude/settings.local.json")
	label=$(basename "$repo")
	assert_eq "--apply-all: ${label} has 3 rules" "3" "$count"
done

# ============================================================
# Test: --diff produces output
# ============================================================

# Remove a rule from wt1 to create a diff
cat >"$REPO_WT1/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git push *)"]
  }
}
EOF

cd "$REPO_WT1"
diff_out=$(bash "$SYNC_SCRIPT" --diff 2>&1)
# Should show the missing rules
assert_contains "--diff shows missing cargo rule" "Bash(cargo build *)" "$diff_out"

# ============================================================
# Test: No worktrees → graceful message
# ============================================================

cd "$REPO_STANDALONE"
out=$(bash "$SYNC_SCRIPT" 2>&1)
assert_contains "standalone: graceful no-worktrees message" "No sibling worktrees" "$out"

# ============================================================
# Test: --from-log includes log-based rules
# ============================================================

# Create a log file with an entry matching a worktree CWD
LOG_FILE="${TMP_DIR}/test-log.jsonl"
jq -nc \
	--arg cwd "$REPO_MAIN" \
	'{timestamp: "2024-01-01T00:00:00Z", tool: "Bash", rule: "Bash(docker ps *)", cwd: $cwd}' \
	>"$LOG_FILE"

cd "$REPO_MAIN"
out=$(CLAUDE_PERMISSION_LOG="$LOG_FILE" bash "$SYNC_SCRIPT" --from-log --preview 2>&1)
assert_contains "--from-log includes log rule" "Bash(docker ps *)" "$out"

cd "$ORIG_DIR"

echo ""
echo "1..${TEST_NUM}"
echo "# pass ${PASS}/${TEST_NUM}"
if [[ $FAIL -gt 0 ]]; then
	echo "# FAIL ${FAIL}"
	exit 1
fi
