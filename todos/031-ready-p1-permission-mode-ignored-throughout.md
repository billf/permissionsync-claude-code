---
status: deferred
priority: p1
issue_id: "031"
tags: [architecture, permission-mode, plan-mode, apply-mode, logging, sync, worktree, major]
dependencies: []
---

# MAJOR: Permission Mode Ignored Throughout — Rules Must Be Mode-Scoped

## Problem Statement

The entire permissionsync pipeline ignores `CLAUDE_PERMISSION_MODE` (plan/apply/auto/log)
when logging, syncing, and surfacing rules. A rule approved in `apply` mode can be
replayed in `plan` mode and vice versa. Worktree sync and session-end sync promote rules
across modes without any awareness of which mode they were approved under. This is
architecturally incorrect: a Bash rule approved in `apply` mode should NOT be auto-approved
in `plan` mode (where it could cause unintended write operations during planning), and a
rule approved in `plan` mode (likely read-only) should be automatically trusted in `apply`
as well.

This is the highest-impact unfixed correctness issue in the project.

## Findings

### What the current code does (wrong)

- `permissionsync-log-permission.sh` logs `rule` as a plain string (e.g. `"Bash(git status)"`)
  with no `permission_mode` field in the JSONL record
- `permissionsync-sync.sh` reads all rules from the log and promotes them all to
  `settings.json` permissions regardless of which mode they were logged under
- `permissionsync-worktree-sync.sh` propagates rules from sibling worktrees without
  checking mode
- Auto-approve (`SEEN_BEFORE`) checks only `"rule":"..."` — not `("mode","rule")`

### What it should do

Rules are **mode-scoped tuples**: `("plan", "Bash(git status)")` and
`("apply", "Bash(git status)")` are different approvals requiring independent user confirmation.

### Mode hierarchy

```
plan < apply < admin   (read permissions)
admin > apply > plan   (write trust)
```

- Approved in `plan` → also safe in `apply` (plan is read-oriented; anything safe to plan
  is safe to apply too) — this is an upgrade promotion
- Approved in `apply` → NOT auto-approved in `plan` (apply rules may involve write
  operations that are inappropriate during planning sessions)
- Always-safe subcommands (`git status`, `git log`, etc.) and always-safe binaries
  (`cat`, `ls`, etc.) — safe at any mode level

### Settings.json representation

Currently rules are stored as:
```json
{"type": "allow", "tool": "Bash", "subcommand": "git status"}
```

They need a `permission_mode` field (or a separate per-mode allow list):
```json
{"type": "allow", "tool": "Bash", "subcommand": "git status", "permission_mode": "plan"}
```

Or structured as separate sections:
```json
{
  "permissions": {
    "allow": [
      {"type": "allow", "tool": "Bash", "subcommand": "git status"}
    ],
    "plan_allow": [
      {"type": "allow", "tool": "Bash", "subcommand": "git status"}
    ]
  }
}
```

The simpler path is adding `permission_mode` to each allow entry and filtering on read.

## Required Changes (by component)

### 1. JSONL log format (breaking change to schema)

Add `permission_mode` field to all JSONL log records in:
- `permission-approvals.jsonl` (logged by `permissionsync-log-permission.sh`)
- `confirmed-approvals.jsonl` (logged by `permissionsync-log-confirmed.sh`)
- Any future log consumers

The `CLAUDE_PERMISSION_MODE` env var is available in the hook at request time.

### 2. Auto-approve logic (permissionsync-log-permission.sh)

The `SEEN_BEFORE` check must be mode-scoped:
```bash
# Current (wrong):
grep -qF "\"rule\":\"${RULE}\"" "$LOG_FILE"

# Correct:
grep -qF "\"rule\":\"${RULE}\",\"permission_mode\":\"${CLAUDE_PERMISSION_MODE}\"" "$LOG_FILE"
# OR use jq: select(.rule == $rule and .permission_mode == $mode)
```

But also implement hierarchy: if SEEN_BEFORE in `plan` mode and current mode is `apply`,
consider it pre-approved (plan ⊂ apply trust).

### 3. Sync pipeline (permissionsync-sync.sh)

When syncing from JSONL to settings.json:
- Group rules by `permission_mode`
- Only add `apply`-mode rules to the main `permissions.allow` list
- Add `plan`-mode rules to a `plan_allow` list (or with a mode annotation)
- Alternatively: add mode-annotated entries and let the hook filter at runtime

### 4. Worktree sync (permissionsync-worktree-sync.sh)

When propagating rules from sibling worktrees:
- Only propagate rules whose `permission_mode` matches (or is dominated by) the current
  session's mode
- A rule from a sibling `plan` session should propagate to other `plan` sessions and
  `apply` sessions; a rule from a sibling `apply` session should NOT propagate to `plan`

### 5. Settings.json allow list

Decide on representation:
- **Option A**: Single `permissions.allow` list with `permission_mode` field per entry;
  at hook time, filter to entries where mode hierarchy allows it
- **Option B**: Separate `permissions.plan_allow` and `permissions.apply_allow` lists
- **Option C**: Keep `permissions.allow` for globally-safe (any mode) rules; add
  `permissions.plan_only_allow` for plan-restricted rules; `apply_allow` for apply-specific

Option A is the most compatible with Claude Code's existing allow-list format.
Option C most cleanly expresses the intent.

### 6. Always-safe list

`permissionsync-config.sh` already has safe subcommands and always-safe binaries.
These should be marked as safe at ALL mode levels (no mode restriction needed).

## Acceptance Criteria

- [ ] `permission_mode` captured in all JSONL log records
- [ ] Auto-approve checks mode-scoped: `("plan","Bash(foo)")` and `("apply","Bash(foo)")` are independent
- [ ] Mode hierarchy implemented: plan-approved rules auto-approved in apply (but not vice versa)
- [ ] `permissionsync-sync.sh` produces mode-annotated rules in settings.json
- [ ] `permissionsync-worktree-sync.sh` respects mode when propagating rules
- [ ] `permissionsync status` reports per-mode rule counts
- [ ] Tests cover mode-scoped approval, hierarchy promotion, and sync behavior
- [ ] Existing tests remain passing
- [ ] Migration path documented for existing logs (no `permission_mode` field)

## Design Notes

This requires a planning session before implementation. The settings.json representation
decision (Option A/B/C above) has downstream implications for all components. Plan first,
then implement as a series of coordinated changes.

The JSONL schema change is backward-compatible (missing `permission_mode` field → treat as
`apply` mode for migration, since old logs predate mode awareness).

## Work Log

### 2026-03-02 - Identified as major architectural omission

**By:** User (via conversation)

**Actions:**
- Identified permission_mode is not captured anywhere in the logging/sync pipeline
- Rules should be mode-scoped tuples: ("mode", "rule")
- Hierarchy: plan ⊂ apply trust; apply ⊄ plan trust
- Always-safe and read-only subcommands are mode-agnostic
- This needs a dedicated design/planning session before implementation
