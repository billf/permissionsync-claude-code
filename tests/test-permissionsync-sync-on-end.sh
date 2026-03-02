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

assert_file_contains() {
	local desc="$1" pattern="$2" file="$3"
	TEST_NUM=$((TEST_NUM + 1))
	if grep -qF "$pattern" "$file" 2>/dev/null; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   pattern not found: '${pattern}'"
		echo "#   in file: '$file'"
		FAIL=$((FAIL + 1))
	fi
}

assert_file_absent() {
	local desc="$1" file="$2"
	TEST_NUM=$((TEST_NUM + 1))
	if [[ ! -f $file ]]; then
		echo "ok ${TEST_NUM} - ${desc}"
		PASS=$((PASS + 1))
	else
		echo "not ok ${TEST_NUM} - ${desc}"
		echo "#   file exists but should not: '$file'"
		FAIL=$((FAIL + 1))
	fi
}

echo "TAP version 13"

# ---------------------------------------------------------------------------
# Fixture: stub permissionsync-sync.sh that records its arguments
# ---------------------------------------------------------------------------
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

# Copy sync-on-end to stub dir so SCRIPT_DIR resolves to there
cp "${SCRIPT_DIR}/../permissionsync-sync-on-end.sh" "${STUB_DIR}/"

run_hook() {
	local reason="${1:-end}"
	local input
	input=$(jq -nc --arg reason "$reason" '{reason: $reason}')
	# Override log location so sync-errors land in TMP_DIR
	CLAUDE_PERMISSION_LOG="${TMP_DIR}/permission-approvals.jsonl" \
		bash "${STUB_DIR}/permissionsync-sync-on-end.sh" <<<"$input"
}

# ---------------------------------------------------------------------------
# Test 1: Normal session end — invokes permissionsync-sync.sh
# ---------------------------------------------------------------------------
run_hook "end"
assert_eq "permissionsync-sync.sh is invoked on session end (reason=end)" \
	"1" "$(wc -l <"$INVOCATIONS_LOG" | tr -d ' ')"

# ---------------------------------------------------------------------------
# Test 2: Normal session end — passes --from-confirmed --apply
# ---------------------------------------------------------------------------
args=$(cat "$INVOCATIONS_LOG")
assert_eq "permissionsync-sync.sh called with --from-confirmed --apply" \
	"--from-confirmed --apply" "$args"

# ---------------------------------------------------------------------------
# Test 3: reason=clear — sync is skipped entirely
# ---------------------------------------------------------------------------
rm -f "$INVOCATIONS_LOG"
run_hook "clear"
INVOCATION_COUNT=0
[[ -f $INVOCATIONS_LOG ]] && INVOCATION_COUNT=$(wc -l <"$INVOCATIONS_LOG" | tr -d ' ')
assert_eq "permissionsync-sync.sh is NOT invoked on reason=clear" \
	"0" "$INVOCATION_COUNT"

# ---------------------------------------------------------------------------
# Test 4: reason=clear — exits 0
# ---------------------------------------------------------------------------
set +e
CLAUDE_PERMISSION_LOG="${TMP_DIR}/permission-approvals.jsonl" \
	bash "${STUB_DIR}/permissionsync-sync-on-end.sh" <<<'{"reason":"clear"}'
exit_code=$?
set -e
assert_exit "exits 0 on reason=clear" "0" "$exit_code"

# ---------------------------------------------------------------------------
# Test 5: Exits 0 when permissionsync-sync.sh is absent
# ---------------------------------------------------------------------------
ABSENT_DIR="${TMP_DIR}/absent"
mkdir -p "$ABSENT_DIR"
cp "${SCRIPT_DIR}/../permissionsync-sync-on-end.sh" "${ABSENT_DIR}/"
set +e
CLAUDE_PERMISSION_LOG="${TMP_DIR}/permission-approvals.jsonl" \
	bash "${ABSENT_DIR}/permissionsync-sync-on-end.sh" <<<'{"reason":"end"}'
exit_code=$?
set -e
assert_exit "exits 0 when permissionsync-sync.sh is absent" "0" "$exit_code"

# ---------------------------------------------------------------------------
# Test 6: Exits 0 when permissionsync-sync.sh fails
# ---------------------------------------------------------------------------
FAIL_DIR="${TMP_DIR}/fail"
mkdir -p "$FAIL_DIR"
cat >"${FAIL_DIR}/permissionsync-sync.sh" <<'FAILSTUB'
#!/usr/bin/env bash
exit 1
FAILSTUB
chmod +x "${FAIL_DIR}/permissionsync-sync.sh"
cp "${SCRIPT_DIR}/../permissionsync-sync-on-end.sh" "${FAIL_DIR}/"
set +e
CLAUDE_PERMISSION_LOG="${TMP_DIR}/permission-approvals.jsonl" \
	bash "${FAIL_DIR}/permissionsync-sync-on-end.sh" <<<'{"reason":"end"}'
exit_code=$?
set -e
assert_exit "exits 0 when permissionsync-sync.sh fails" "0" "$exit_code"

# ---------------------------------------------------------------------------
# Test 7: Sync failure is logged to sync-on-end-errors.log
# ---------------------------------------------------------------------------
ERR_LOG_DIR="${TMP_DIR}/err-log-dir"
mkdir -p "$ERR_LOG_DIR"

FAIL2_DIR="${TMP_DIR}/fail2"
mkdir -p "$FAIL2_DIR"
cat >"${FAIL2_DIR}/permissionsync-sync.sh" <<'FAILSTUB2'
#!/usr/bin/env bash
echo "mock sync error" >&2
exit 1
FAILSTUB2
chmod +x "${FAIL2_DIR}/permissionsync-sync.sh"
cp "${SCRIPT_DIR}/../permissionsync-sync-on-end.sh" "${FAIL2_DIR}/"

CLAUDE_PERMISSION_LOG="${ERR_LOG_DIR}/permission-approvals.jsonl" \
	bash "${FAIL2_DIR}/permissionsync-sync-on-end.sh" <<<'{"reason":"end"}' 2>/dev/null || true

assert_file_contains "sync failure is written to sync-on-end-errors.log" \
	"mock sync error" "${ERR_LOG_DIR}/sync-on-end-errors.log"

# ---------------------------------------------------------------------------
# Test 8: reason=clear — no error log created (sync never ran)
# ---------------------------------------------------------------------------
CLEAR_LOG_DIR="${TMP_DIR}/clear-log-dir"
mkdir -p "$CLEAR_LOG_DIR"

CLEAR_DIR="${TMP_DIR}/clear"
mkdir -p "$CLEAR_DIR"
# Even a failing stub — it should not be invoked on reason=clear
cat >"${CLEAR_DIR}/permissionsync-sync.sh" <<'CLEARSTUB'
#!/usr/bin/env bash
echo "should not run" >&2
exit 1
CLEARSTUB
chmod +x "${CLEAR_DIR}/permissionsync-sync.sh"
cp "${SCRIPT_DIR}/../permissionsync-sync-on-end.sh" "${CLEAR_DIR}/"

CLAUDE_PERMISSION_LOG="${CLEAR_LOG_DIR}/permission-approvals.jsonl" \
	bash "${CLEAR_DIR}/permissionsync-sync-on-end.sh" <<<'{"reason":"clear"}' 2>/dev/null || true

assert_file_absent "no sync-on-end-errors.log created on reason=clear" \
	"${CLEAR_LOG_DIR}/sync-on-end-errors.log"

echo "1..${TEST_NUM}"
echo "# pass: ${PASS}"
echo "# fail: ${FAIL}"

[[ $FAIL -eq 0 ]]
