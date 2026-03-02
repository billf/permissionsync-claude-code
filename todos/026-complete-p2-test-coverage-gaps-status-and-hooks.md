---
status: complete
priority: p2
issue_id: "026"
tags: [testing, code-review, coverage]
dependencies: []
---

# Test Coverage Gaps: Legacy Status Mode Detection + Secondary Hooks

## Problem Statement

Two coverage gaps identified in this branch:

1. **Legacy mode detection in `permissionsync status`**: The new `(legacy — re-run installer to upgrade)` logic added to `permissionsync.sh` has zero test coverage. No test sets up a `settings.json` with old-style env vars (`CLAUDE_PERMISSION_WORKTREE=1`, `CLAUDE_PERMISSION_AUTO=1`, bare `log-permission.sh`) and asserts the status output includes the correct legacy mode string.

2. **Secondary hooks not verified by installer tests**: Both `test-install.sh` and `test-setup-hooks.sh` only assert on the `PermissionRequest` hook. The six additional hooks wired by both installers (PostToolUse, PostToolUseFailure, ConfigChange, SessionEnd, SessionStart, WorktreeCreate) have no assertions in the test files.

## Findings

- `permissionsync.sh` lines 63–76: legacy mode detection added in commit `be43965` — no corresponding test
- `tests/test-permissionsync-dispatcher.sh` tests 17–20 only verify `status` exits 0 and outputs section headers; do not test mode detection
- `tests/test-install.sh`: assertions cover PermissionRequest hook command and mode, `log-confirmed.sh` copy, and worktree-sync copy — but NOT PostToolUseFailure, ConfigChange, SessionEnd, SessionStart, or WorktreeCreate hooks
- `tests/test-setup-hooks.sh`: similar gap — only asserts on PermissionRequest and PostToolUse

## Proposed Solutions

### Option 1: Add targeted tests for both gaps (Recommended)

**For legacy mode detection** — add to `test-permissionsync-dispatcher.sh` or a new `test-permissionsync-status.sh`:

```bash
# Set up settings.json with old-style CLAUDE_PERMISSION_WORKTREE=1 hook
FAKE_SETTINGS=$(mktemp)
jq -nc '{hooks:{PermissionRequest:[{matcher:"*",hooks:[{type:"command",command:"CLAUDE_PERMISSION_WORKTREE=1 CLAUDE_PERMISSION_AUTO=1 /home/user/.claude/hooks/log-permission-auto.sh"}]}]}}' > "$FAKE_SETTINGS"
HOME_OVERRIDE=$(mktemp -d)
mkdir -p "$HOME_OVERRIDE/.claude"
cp "$FAKE_SETTINGS" "$HOME_OVERRIDE/.claude/settings.json"
output=$(HOME="$HOME_OVERRIDE" bash "$DISPATCHER" status 2>/dev/null)
assert_contains "legacy worktree mode shown in status" "worktree (legacy" "$output"
```

**For installer hook coverage** — add assertions for each of the 6 additional hooks in both test files:
- PostToolUse hook wired with `permissionsync-log-confirmed.sh`
- PostToolUseFailure hook wired with `permissionsync-log-hook-errors.sh`
- ConfigChange hook wired with `permissionsync-watch-config.sh`
- SessionEnd hook wired with `permissionsync-sync-on-end.sh`
- SessionStart hook wired with `permissionsync-session-start.sh`
- WorktreeCreate hook wired with `permissionsync-worktree-create.sh`

### Option 2: Add a dedicated test-permissionsync-status.sh

Extract all status tests to a dedicated file covering the full range of settings.json states.

- **Effort**: Medium
- **Risk**: Low

## Recommended Action

Option 1 — add tests inline to existing files for the gaps. The legacy mode detection tests go in `test-permissionsync-dispatcher.sh` (it already tests `status`). The installer hook assertions go in `test-install.sh` and `test-setup-hooks.sh`.

## Technical Details

- **Affected Files**: `tests/test-permissionsync-dispatcher.sh`, `tests/test-install.sh`, `tests/test-setup-hooks.sh`
- **Related**: `permissionsync.sh` lines 63–76; `permissionsync-install.sh` steps 4–9; `permissionsync-setup.sh` steps 4–9

## Acceptance Criteria

- [ ] At least 3 test cases for legacy mode detection: worktree, auto, and log variants of old-style env var hook commands
- [ ] `test-install.sh` asserts all 6 secondary hooks are present in settings.json after install
- [ ] `test-setup-hooks.sh` asserts all 6 secondary hooks are present in settings.json after setup
- [ ] All tests pass

## Work Log

### 2026-03-02 - Identified in code review

**By:** Pattern review agent
