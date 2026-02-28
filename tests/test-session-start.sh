#!/usr/bin/env bash
# test-session-start.sh — unit tests for session-start.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
TEST_NUM=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
		echo "#   actual: '${haystack}'"
		FAIL=$((FAIL + 1))
	fi
}

assert_exit() {
	local desc="$1" expected="$2" actual="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if [[ $expected == "$actual" ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   expected exit: '${expected}'"
		echo "#   actual exit:   '${actual}'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# Helper: create a stub sync-permissions.sh in a tmp dir alongside session-start.sh
make_env() {
	local dir="$1"
	mkdir -p "$dir"
	cp "${SCRIPT_DIR}/../session-start.sh" "$dir/"
}

run_hook() {
	local dir="$1"
	bash "${dir}/session-start.sh" </dev/null
}

# --- Test 1: Silent when sync-permissions.sh is absent ---
ABSENT_DIR="${TMP_DIR}/absent"
make_env "$ABSENT_DIR"
set +e
output=$(run_hook "$ABSENT_DIR" 2>&1)
exit_code=$?
set -e
assert_exit "exits 0 when sync-permissions.sh is absent" "0" "$exit_code"
assert_eq "no output when sync-permissions.sh is absent" "" "$output"

# --- Test 2: Silent when no pending rules ---
NOCHANGE_DIR="${TMP_DIR}/nochange"
make_env "$NOCHANGE_DIR"
cat >"${NOCHANGE_DIR}/sync-permissions.sh" <<'STUB'
#!/usr/bin/env bash
echo "2c2"
echo "< old"
echo "---"
echo "< different"
exit 0
STUB
chmod +x "${NOCHANGE_DIR}/sync-permissions.sh"
set +e
output=$(run_hook "$NOCHANGE_DIR" 2>&1)
exit_code=$?
set -e
assert_exit "exits 0 when no new rules (no > lines)" "0" "$exit_code"
assert_eq "no output when no > lines in diff" "" "$output"

# --- Test 3: Shows count and commands when pending rules exist ---
PENDING_DIR="${TMP_DIR}/pending"
make_env "$PENDING_DIR"
cat >"${PENDING_DIR}/sync-permissions.sh" <<'STUB'
#!/usr/bin/env bash
echo '> "Bash(git *)"'
echo '> "Bash(cargo *)"'
exit 0
STUB
chmod +x "${PENDING_DIR}/sync-permissions.sh"
output=$(run_hook "$PENDING_DIR" 2>&1)
assert_contains "shows new rule count" "2 new rule(s)" "$output"
assert_contains "shows --apply command" "sync-permissions.sh --apply" "$output"
assert_contains "shows --refine --apply command" "sync-permissions.sh --refine --apply" "$output"

# --- Test 4: Includes the diff lines in output ---
assert_contains "includes diff output" '"Bash(git *)"' "$output"
assert_contains "includes second diff line" '"Bash(cargo *)"' "$output"

# --- Test 5: Exits 0 when sync-permissions.sh fails ---
FAIL_DIR="${TMP_DIR}/fail"
make_env "$FAIL_DIR"
cat >"${FAIL_DIR}/sync-permissions.sh" <<'FAILSTUB'
#!/usr/bin/env bash
exit 1
FAILSTUB
chmod +x "${FAIL_DIR}/sync-permissions.sh"
set +e
bash "${FAIL_DIR}/session-start.sh" </dev/null
exit_code=$?
set -e
assert_exit "exits 0 when sync-permissions.sh fails" "0" "$exit_code"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
