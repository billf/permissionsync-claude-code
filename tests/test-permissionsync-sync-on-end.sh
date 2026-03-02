#!/usr/bin/env bash
# test-permissionsync-sync-on-end.sh — unit tests for permissionsync-sync-on-end.sh
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

# Create a stub permissionsync-sync.sh that records invocations
STUB_DIR="${TMP_DIR}/stub"
mkdir -p "$STUB_DIR"
INVOCATIONS_LOG="${TMP_DIR}/invocations.log"

export INVOCATIONS_LOG
cat >"${STUB_DIR}/permissionsync-sync.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$INVOCATIONS_LOG"
exit 0
STUB
chmod +x "${STUB_DIR}/permissionsync-sync.sh"

# Copy sync-on-end to stub dir so SCRIPT_DIR points there
cp "${SCRIPT_DIR}/../permissionsync-sync-on-end.sh" "${STUB_DIR}/"

run_hook() {
	local reason="${1:-clear}"
	local input
	input=$(jq -nc --arg reason "$reason" '{reason: $reason}')
	bash "${STUB_DIR}/permissionsync-sync-on-end.sh" <<<"$input"
}

# --- Test 1: Invokes permissionsync-sync.sh ---
run_hook "clear"
assert_eq "permissionsync-sync.sh is invoked on session end" "1" "$(wc -l <"$INVOCATIONS_LOG" | tr -d ' ')"

# --- Test 2: Passes --apply to permissionsync-sync.sh ---
args=$(cat "$INVOCATIONS_LOG")
assert_eq "permissionsync-sync.sh called with --apply" "--apply" "$args"

# --- Test 3: Exits 0 when permissionsync-sync.sh is absent ---
ABSENT_DIR="${TMP_DIR}/absent"
mkdir -p "$ABSENT_DIR"
cp "${SCRIPT_DIR}/../permissionsync-sync-on-end.sh" "${ABSENT_DIR}/"
set +e
bash "${ABSENT_DIR}/permissionsync-sync-on-end.sh" <<<'{"reason":"clear"}'
exit_code=$?
set -e
assert_exit "exits 0 when permissionsync-sync.sh is absent" "0" "$exit_code"

# --- Test 4: Exits 0 when permissionsync-sync.sh fails ---
FAIL_DIR="${TMP_DIR}/fail"
mkdir -p "$FAIL_DIR"
cat >"${FAIL_DIR}/permissionsync-sync.sh" <<'FAILSTUB'
#!/usr/bin/env bash
exit 1
FAILSTUB
chmod +x "${FAIL_DIR}/permissionsync-sync.sh"
cp "${SCRIPT_DIR}/../permissionsync-sync-on-end.sh" "${FAIL_DIR}/"
set +e
bash "${FAIL_DIR}/permissionsync-sync-on-end.sh" <<<'{"reason":"clear"}'
exit_code=$?
set -e
assert_exit "exits 0 when permissionsync-sync.sh fails" "0" "$exit_code"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
