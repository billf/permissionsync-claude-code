---
status: complete
priority: p2
issue_id: "030"
tags: [status, dispatcher, coverage, ux]
dependencies: []
---

# permissionsync status Only Reports PermissionRequest Hook

## Problem Statement

`permissionsync status` currently extracts the `PermissionRequest` hook command from
`settings.json` and reports it as "PermissionRequest: installed (mode: log)" etc. The
seven other hooks wired by the installer (PostToolUse, PostToolUseFailure, ConfigChange,
SessionEnd, SessionStart, WorktreeCreate) are never shown. A user re-running
`permissionsync status` after install sees an incomplete picture and cannot tell whether
the secondary hooks are actually present in their settings.

## Findings

- `permissionsync.sh` cmd_status() — only reads `.hooks.PermissionRequest` path
- Installer wires 7 hooks total; status shows 1
- A user whose PostToolUse hook was removed would not see this in `permissionsync status`
- Misleading: a clean status output suggests full installation even if 6 of 7 hooks are missing

## Proposed Solutions

### Option 1: Show all 7 hooks with installed/missing status (Recommended)

Extend cmd_status() to check each expected hook command and report:

```
PermissionRequest:   installed (mode: log)
PostToolUse:         installed (permissionsync-log-confirmed.sh)
PostToolUseFailure:  installed (permissionsync-log-hook-errors.sh)
ConfigChange:        installed (permissionsync-watch-config.sh)
SessionEnd:          installed (permissionsync-sync-on-end.sh)
SessionStart:        installed (permissionsync-session-start.sh)
WorktreeCreate:      installed (permissionsync-worktree-create.sh)
```

Show "missing" (with a warning) for any hook not found in settings.json.

- **Pros**: Complete installation visibility; can detect partial uninstalls
- **Cons**: Slightly longer output
- **Effort**: Small
- **Risk**: Low

### Option 2: Add a simple count only

Report "PermissionRequest: installed (mode: log) + 6/6 secondary hooks" without
listing each one.

- **Pros**: Brief
- **Cons**: Doesn't tell the user which hooks are missing if count is off
- **Effort**: Trivial
- **Risk**: Low

## Recommended Action

Option 1. The status command is the primary diagnostic tool for users; showing all
7 hooks with installed/missing gives clear visibility that matches `permissionsync-watch-config.sh`'s own guard logic.

## Technical Details

- **Affected Files**: `permissionsync.sh` cmd_status(), `tests/test-permissionsync-dispatcher.sh`
- **Related**: `permissionsync-watch-config.sh` (already checks 5 of the 7 hooks)

## Acceptance Criteria

- [ ] `permissionsync status` output includes a line for each of the 7 expected hooks
- [ ] Each line shows "installed (script-name)" or "missing"
- [ ] Tests cover both full-install and partial-install scenarios
- [ ] All existing status tests pass

## Work Log

### 2026-03-02 - Added during todo resolution planning

**By:** User (via conversation)

**Actions:**
- Identified gap: status only reports PermissionRequest, not 6 secondary hooks
- Created todo for visibility improvement
