#!/usr/bin/env bash
# test-permissionsync-dispatcher.sh — tests for permissionsync.sh dispatcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCHER="${SCRIPT_DIR}/../permissionsync.sh"

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

# Build a fake scripts directory so dispatcher delegates to our stubs
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INVOKED="${TMP_DIR}/invoked"
export INVOKED

# Create a stub factory: each stub records its name and args
make_stub() {
	local name="$1"
	local stub="${TMP_DIR}/${name}"
	cat >"$stub" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >>"$INVOKED"
EOF
	chmod +x "$stub"
}

make_stub "sync-permissions.sh"
make_stub "worktree-sync.sh"
make_stub "merged-settings.sh"
make_stub "permissionsync-launch.sh"
make_stub "install.sh"

# Copy dispatcher alongside stubs (so SCRIPT_DIR finds them)
DISPATCHER_COPY="${TMP_DIR}/permissionsync.sh"
cp "$DISPATCHER" "$DISPATCHER_COPY"

run_dispatcher() {
	>"$INVOKED"
	bash "$DISPATCHER_COPY" "$@"
}

# --- Test 1: No args exits non-zero ---
assert_exit_nonzero "no args exits non-zero" bash "$DISPATCHER_COPY"

# --- Test 2: Unknown subcommand exits non-zero ---
assert_exit_nonzero "unknown subcommand exits non-zero" bash "$DISPATCHER_COPY" bogus

# --- Test 3: help exits 0 ---
TEST_NUM=$((TEST_NUM + 1))
if bash "$DISPATCHER_COPY" --help >/dev/null 2>&1; then
	echo "ok ${TEST_NUM} - help exits 0"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - help exits 0"
	FAIL=$((FAIL + 1))
fi

# --- Test 4: sync delegates to sync-permissions.sh ---
run_dispatcher sync --apply
recorded=$(cat "$INVOKED")
assert_contains "sync delegates to sync-permissions.sh" "sync-permissions.sh" "$recorded"
assert_contains "sync passes --apply through" "--apply" "$recorded"

# --- Test 5: worktree delegates to worktree-sync.sh ---
run_dispatcher worktree --report
recorded=$(cat "$INVOKED")
assert_contains "worktree delegates to worktree-sync.sh" "worktree-sync.sh" "$recorded"
assert_contains "worktree passes --report through" "--report" "$recorded"

# --- Test 6: settings delegates to merged-settings.sh ---
run_dispatcher settings --refine
recorded=$(cat "$INVOKED")
assert_contains "settings delegates to merged-settings.sh" "merged-settings.sh" "$recorded"
assert_contains "settings passes --refine through" "--refine" "$recorded"

# --- Test 7: launch delegates to permissionsync-launch.sh ---
run_dispatcher launch --dry-run my-feature
recorded=$(cat "$INVOKED")
assert_contains "launch delegates to permissionsync-launch.sh" "permissionsync-launch.sh" "$recorded"
assert_contains "launch passes worktree name through" "my-feature" "$recorded"

# --- Test 8: install with no mode calls install.sh with no args ---
run_dispatcher install
recorded=$(cat "$INVOKED")
assert_contains "install delegates to install.sh" "install.sh" "$recorded"

# --- Test 9: install --mode=auto translates to --auto ---
run_dispatcher install --mode=auto
recorded=$(cat "$INVOKED")
assert_contains "install --mode=auto passes --auto" "--auto" "$recorded"

# --- Test 10: install --mode=worktree translates to --worktree ---
run_dispatcher install --mode=worktree
recorded=$(cat "$INVOKED")
assert_contains "install --mode=worktree passes --worktree" "--worktree" "$recorded"

# --- Test 11: install --mode=log passes no mode arg ---
run_dispatcher install --mode=log
recorded=$(cat "$INVOKED")
# Should have called install.sh but without --auto or --worktree
assert_contains "install --mode=log calls install.sh" "install.sh" "$recorded"
TEST_NUM=$((TEST_NUM + 1))
if ! echo "$recorded" | grep -qF -- "--auto" && ! echo "$recorded" | grep -qF -- "--worktree"; then
	echo "ok ${TEST_NUM} - install --mode=log passes no mode flag"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - install --mode=log passes no mode flag"
	echo "#   recorded: '$recorded'"
	FAIL=$((FAIL + 1))
fi

# --- Test 12: status subcommand runs without error ---
TEST_NUM=$((TEST_NUM + 1))
if bash "$DISPATCHER_COPY" status >/dev/null 2>/dev/null; then
	echo "ok ${TEST_NUM} - status exits 0"
	PASS=$((PASS + 1))
else
	echo "not ok ${TEST_NUM} - status exits 0"
	FAIL=$((FAIL + 1))
fi

# --- Test 13: status output contains expected sections ---
output=$(bash "$DISPATCHER_COPY" status 2>/dev/null)
assert_contains "status shows permissionsync-cc header" "permissionsync-cc" "$output"
assert_contains "status shows Hooks section" "Hooks:" "$output"
assert_contains "status shows Settings section" "Settings" "$output"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
