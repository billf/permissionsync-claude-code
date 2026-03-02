---
status: ready
priority: p1
issue_id: "006"
tags: [security, session-end, sync, data-integrity]
dependencies: []
---

# SessionEnd auto-sync reads from wrong log — promotes denied permissions

## Problem Statement

`permissionsync-sync-on-end.sh` invokes `sync-permissions.sh --apply` at session end. This reads from `permission-approvals.jsonl`, which records every permission *request* — including ones the user **denied**. As a result, denied tool calls can be silently promoted into `settings.json`'s `permissions.allow` list at session end.

## Findings

**Root cause:** `log-permission-auto.sh` (lines 73–84) writes to `permission-approvals.jsonl` unconditionally when a `PermissionRequest` event fires — before the user decides. No `decision` or `outcome` field is written. `sync-permissions.sh --apply` reads from this log and promotes every entry found.

**Concrete exploit scenario:**
1. Claude Code requests `Bash(rm -rf /tmp/foo)`
2. User denies the prompt
3. `permission-approvals.jsonl` already contains `Bash(rm *)` (written before denial)
4. At session end, `sync --apply` adds `Bash(rm *)` to `settings.json` `permissions.allow`
5. Next session: all `rm` invocations auto-approved without a prompt

**The correct log is `confirmed-approvals.jsonl`**, populated exclusively by the `PostToolUse` hook (`log-confirmed.sh`). `PostToolUse` only fires when a tool *successfully executes*, meaning the user approved and Claude ran the command.

The `--from-confirmed` flag already exists in `sync-permissions.sh` for exactly this purpose.

**Confirmed:** `filter_rules` in `permissionsync-lib.sh` does not block `rm` — it only covers interpreter binaries. `Bash(rm *)` passes through cleanly.

## Proposed Solutions

### Option A — Use `--from-confirmed` flag (recommended)

Change `permissionsync-sync-on-end.sh` line 11:
```bash
# Before
"$SYNC" --apply >/dev/null 2>&1 || true

# After
"$SYNC" --from-confirmed --apply >/dev/null 2>&1 || true
```

**Pros:** Correct semantics — only promotes tools the user actually approved and Claude executed. One-line fix. Matches documented intent of the confirmed-approvals system.
**Cons:** None.
**Effort:** trivial
**Risk:** low

### Option B — Add `decision` field to permission-approvals.jsonl, filter on sync

Modify `log-permission-auto.sh` to record the user's decision, then filter in `sync-permissions.sh`.

**Pros:** Richer audit log.
**Cons:** Requires changes to the PermissionRequest hook output format, which doesn't reliably carry decision outcomes in Claude Code's hook API.
**Effort:** large
**Risk:** high (Claude Code API dependency)

## Recommended Action

*(Filled during triage — clear implementation plan)*

## Acceptance Criteria

- [ ] `permissionsync-sync-on-end.sh` uses `--from-confirmed` (or equivalent) so only executed tool calls are synced
- [ ] `tests/test-permissionsync-sync-on-end.sh` verifies the correct flag/log is used
- [ ] Running sync after a deny-only session does not add any rules to `settings.json`

## Work Log

### 2026-03-01 — Triage approved

**By:** Claude Triage System

**Actions:**
- Issue approved during triage session
- Status changed from pending → ready
- Ready to be picked up and worked on

**Learnings:**
- Highest priority: --from-confirmed flag already exists, fix is one line

### 2026-02-28 — Security audit finding

**By:** Claude Code (security-sentinel agent)

**Actions:**
- Traced `sync-permissions.sh --apply` log source to `permission-approvals.jsonl`
- Confirmed `log-permission-auto.sh` writes unconditionally before user decision
- Confirmed `filter_rules` does not block `rm` or other destructive commands
- Identified `--from-confirmed` flag as the correct fix

**Learnings:**
- The `permission-approvals.jsonl` log and `confirmed-approvals.jsonl` log have distinct semantics: requests vs. approved executions
- The SessionEnd hook must use the executed-approvals source to maintain security invariants
