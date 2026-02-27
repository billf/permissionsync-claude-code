---
status: ready
priority: p3
issue_id: "004"
tags: [docs]
dependencies: ["001", "002", "003"]
---

# Update README with new features

## Problem Statement

The README documents the old two-boolean env var system and doesn't cover:
- `CLAUDE_PERMISSION_MODE` enum
- New safe subcommands (rustup, yarn, pnpm, jj, terraform, fd, rg, etc.)
- Baseline seeding on fresh install
- PostToolUse confirmed-approvals log
- `permissionsync-launch` command
- `permissionsync` unified CLI
- Backward compatibility note for old env vars

## Recommended Action

Update README.md after todos 001-003 are complete. Sections to update:
1. **Quick Start / Install** — note baseline seeding on fresh install
2. **Environment Variables** — replace two-var table with MODE enum, note legacy compat
3. **Safe subcommands** — expand table with new binaries
4. **Launching worktrees** — document `permissionsync-launch` / `permissionsync launch`
5. **CLI reference** — add `permissionsync` subcommand table
6. **Confirmed approvals** — document PostToolUse log and `--from-confirmed` flag

## Acceptance Criteria

- [ ] MODE enum documented with all three values
- [ ] Legacy vars mentioned as still supported
- [ ] New safe subcommands table includes rustup, yarn, pnpm, jj, terraform, fd, rg
- [ ] `permissionsync-launch` usage shown
- [ ] `permissionsync` subcommands documented
- [ ] Confirmed approvals log documented
- [ ] README passes any lint checks

## Work Log

### 2026-02-27 — Todo created

**By:** Claude Code

**Actions:**
- Created; blocked on todos 001-003 completing first
