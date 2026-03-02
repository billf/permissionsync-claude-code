#!/usr/bin/env bash
# test-permissionsync-launch.sh — unit tests for permissionsync-launch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH="${SCRIPT_DIR}/../permissionsync-launch.sh"

PASS=0
FAIL=0
TEST_NUM=0

echo "TAP version 13"

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
	local desc="$1" pattern="$2" actual="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if echo "$actual" | grep -qF -- "$pattern"; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected to contain: '${pattern}'"
		echo "#   actual:              '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_not_contains() {
	local desc="$1" pattern="$2" actual="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if ! echo "$actual" | grep -qF -- "$pattern"; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected NOT to contain: '${pattern}'"
		echo "#   actual:                  '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_exit_nonzero() {
	local desc="$1"
	shift
	TEST_NUM=$((TEST_NUM + 1))
	if ! "$@" >/dev/null 2>&1; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected non-zero exit from: $*"
		FAIL=$((FAIL + 1))
	fi
}

# Build a fake permissionsync-settings.sh and claude for testing
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Subdirectory for the launch script copy + its permissionsync-settings.sh sibling
BIN_DIR="${TMP_DIR}/bin"
mkdir -p "$BIN_DIR"

RECORDED_ARGS="${TMP_DIR}/recorded-args"
export RECORDED_ARGS

# Fake permissionsync-settings.sh (placed beside the launch script copy so SCRIPT_DIR resolves it)
cat >"${BIN_DIR}/permissionsync-settings.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"permissions":{"allow":[],"deny":[]}}' >&1
printf 'permissionsync-settings: %s\n' "$*" >>"$RECORDED_ARGS"
EOF
chmod +x "${BIN_DIR}/permissionsync-settings.sh"

# Fake claude (on PATH)
cat >"${TMP_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude: %s\n' "$*" >>"$RECORDED_ARGS"
EOF
chmod +x "${TMP_DIR}/claude"

# Copy launch script into BIN_DIR so it finds permissionsync-settings.sh via SCRIPT_DIR
LAUNCH_COPY="${BIN_DIR}/permissionsync-launch.sh"
cp "$LAUNCH" "$LAUNCH_COPY"

run_launch_from_tmp() {
	: >"$RECORDED_ARGS"
	PATH="${TMP_DIR}:$PATH" bash "$LAUNCH_COPY" "$@"
}

# --- Test 1: Missing worktree name exits non-zero ---
assert_exit_nonzero "missing worktree name exits non-zero" bash "$LAUNCH_COPY"

# --- Test 2: Unknown flag exits non-zero ---
assert_exit_nonzero "unknown flag exits non-zero" bash "$LAUNCH_COPY" --unknown-flag feature-x

# --- Test 3: --dry-run prints claude command ---
output=$(run_launch_from_tmp --dry-run feature-x 2>&1)
assert_contains "--dry-run prints 'claude'" "claude" "$output"
assert_contains "--dry-run prints worktree name" "feature-x" "$output"
assert_contains "--dry-run prints --settings" "--settings" "$output"

# --- Test 4: --dry-run includes --refine by default ---
output=$(run_launch_from_tmp --dry-run feature-x 2>&1)
assert_contains "--dry-run includes --refine by default" "--refine" "$output"

# --- Test 5: --dry-run with --no-refine omits --refine ---
output=$(run_launch_from_tmp --dry-run --no-refine feature-x 2>&1)
assert_not_contains "--no-refine omits --refine from command" "--refine" "$output"

# --- Test 6: --dry-run with --from-log includes --from-log ---
output=$(run_launch_from_tmp --dry-run --from-log feature-x 2>&1)
assert_contains "--from-log appears in dry-run output" "--from-log" "$output"

# --- Test 7: --dry-run with --global-only includes --global-only ---
output=$(run_launch_from_tmp --dry-run --global-only feature-x 2>&1)
assert_contains "--global-only appears in dry-run output" "--global-only" "$output"

# --- Test 8: --dry-run with extra claude args notes them ---
output=$(run_launch_from_tmp --dry-run feature-x -- --resume abc123 2>&1)
assert_contains "--dry-run shows extra claude args" "--resume" "$output"

# --- Test 9: normal launch calls permissionsync-settings.sh ---
run_launch_from_tmp my-feature 2>/dev/null || true
recorded=$(cat "$RECORDED_ARGS")
assert_contains "normal launch invokes permissionsync-settings.sh" "permissionsync-settings:" "$recorded"

# --- Test 10: normal launch passes --refine to permissionsync-settings.sh by default ---
run_launch_from_tmp my-feature 2>/dev/null || true
recorded=$(cat "$RECORDED_ARGS")
assert_contains "normal launch passes --refine to permissionsync-settings.sh" "--refine" "$recorded"

# --- Test 11: normal launch calls claude with -w and --settings ---
run_launch_from_tmp my-feature 2>/dev/null || true
recorded=$(cat "$RECORDED_ARGS")
assert_contains "normal launch calls claude" "claude:" "$recorded"
assert_contains "normal launch passes -w to claude" " -w " "$recorded"
assert_contains "normal launch passes --settings to claude" "--settings" "$recorded"

# --- Test 12: normal launch passes worktree name to claude ---
run_launch_from_tmp my-worktree 2>/dev/null || true
recorded=$(cat "$RECORDED_ARGS")
assert_contains "worktree name passed to claude" "my-worktree" "$recorded"

# --- Test 13: --from-log passes --from-log to permissionsync-settings.sh ---
run_launch_from_tmp --from-log my-feature 2>/dev/null || true
recorded=$(cat "$RECORDED_ARGS")
assert_contains "--from-log forwarded to permissionsync-settings.sh" "--from-log" "$recorded"

# --- Test 14: extra claude args passed through ---
run_launch_from_tmp my-feature -- --resume sess123 2>/dev/null || true
recorded=$(cat "$RECORDED_ARGS")
assert_contains "extra claude args passed through" "--resume" "$recorded"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
