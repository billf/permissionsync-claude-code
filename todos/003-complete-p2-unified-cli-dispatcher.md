---
status: complete
priority: p2
issue_id: "003"
tags: [dx, cli, dispatcher]
dependencies: ["001", "002"]
---

# Unified permissionsync CLI dispatcher

## Problem Statement

Four separate sync scripts (sync-permissions.sh, worktree-sync.sh, merged-settings.sh,
permissionsync-launch) have overlapping flags and different invocation styles. There's
no single entry point or tab-completable CLI. Users must remember which script handles
which operation.

## Findings

The scripts already exist and work. What's missing is a thin dispatcher:
```
permissionsync sync [--apply] [--refine] [--diff]     # → sync-permissions.sh
permissionsync worktree [--apply] [--apply-all]        # → worktree-sync.sh
permissionsync settings [--refine] [--from-log]        # → merged-settings.sh
permissionsync launch [name] [flags]                   # → permissionsync-launch
permissionsync install [--mode=log|auto|worktree]      # → install.sh
permissionsync status                                  # → new: show current state
```

`permissionsync status` output:
```
Mode: worktree (CLAUDE_PERMISSION_MODE=worktree)
Settings rules: 141 (global)
Log entries: 127 total
Hook: installed at ~/.claude/hooks/log-permission-auto.sh
```

## Proposed Solutions

### Option A — Thin dispatcher bash script (Recommended)
A single `permissionsync` script that routes subcommands to existing scripts.
Existing scripts remain the implementations (no logic duplication).

**Pros:** Minimal code, single entry point, works with tab completion
**Cons:** Delegates make errors harder to trace
**Effort:** small
**Risk:** low

### Option B — Rewrite all scripts into one monolith
**Pros:** Single file
**Cons:** Major refactor, high risk, loses clarity
**Effort:** very large
**Risk:** high

## Recommended Action

Implement Option A dispatcher. Key implementation details:

```bash
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

subcmd="${1:-help}"
shift 2>/dev/null || true

case "$subcmd" in
sync)     exec "${SCRIPT_DIR}/sync-permissions.sh" "$@" ;;
worktree) exec "${SCRIPT_DIR}/worktree-sync.sh" "$@" ;;
settings) exec "${SCRIPT_DIR}/merged-settings.sh" "$@" ;;
launch)   exec "${SCRIPT_DIR}/permissionsync-launch" "$@" ;;
install)  exec "${SCRIPT_DIR}/install.sh" "$@" ;;
status)   # inline implementation
          ...
          ;;
help|--help|-h)
          # print usage
          ;;
*)        echo "Unknown subcommand: $subcmd" >&2; exit 1 ;;
esac
```

`status` subcommand reads:
- `~/.claude/settings.json` for hook command (extract MODE) and rule count
- `~/.claude/permission-approvals.jsonl` for log entry count
- `~/.claude/confirmed-approvals.jsonl` for confirmed count (if exists)

Install to `~/.local/bin/permissionsync` when possible.

## Acceptance Criteria

- [ ] `permissionsync sync [flags]` delegates to sync-permissions.sh
- [ ] `permissionsync worktree [flags]` delegates to worktree-sync.sh
- [ ] `permissionsync settings [flags]` delegates to merged-settings.sh
- [ ] `permissionsync launch [name]` delegates to permissionsync-launch
- [ ] `permissionsync install [flags]` delegates to install.sh
- [ ] `permissionsync status` shows mode, rule count, log count, hook path
- [ ] `permissionsync help` prints usage for all subcommands
- [ ] install.sh and setup-hooks.sh install to hooks/ and optionally ~/.local/bin/
- [ ] flake.nix includes in executableScripts
- [ ] Integration tests cover each subcommand

## Work Log

### 2026-02-27 — Todo created

**By:** Claude Code

**Actions:**
- Extracted from implementation plan; depends on 001 (confirmed log) and 002 (launch)

**Learnings:**
- Keep as thin router; don't duplicate logic from existing scripts
- `status` subcommand is the only novel logic in the dispatcher
