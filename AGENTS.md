# AGENTS.md — permissionsync-cc

## Repository Purpose

Pure Bash toolkit for Claude Code's `PermissionRequest` hook system. Logs every tool-permission request to a JSONL file, builds deduplicated permission rules, syncs them into `~/.claude/settings.json` or per-project `settings.local.json`, and optionally auto-approves previously seen or worktree-shared rules. All scripts target Bash 3.2+ (macOS default) — no associative arrays.

## Architecture

```
lib/permissionsync-config.sh  (data: safe subcommand tables, indirection types, blocklists)
  <- lib/permissionsync-lib.sh  (logic: rule building, indirection peeling, worktree discovery)
    <- permissionsync-log-permission-v1.sh  (hook: log-only, legacy)
    <- permissionsync-log-permission.sh     (hook: log + auto-approve)
    <- permissionsync-sync.sh               (worker: log -> settings.json)
    <- permissionsync-worktree-sync.sh      (worker: worktree settings.local.json aggregation)

permissionsync-install.sh   (standalone installer, copies scripts + configures hooks)
permissionsync-setup.sh     (idempotent installer for Nix flake shellHooks)
permissionsync.sh           (unified CLI dispatcher)
```

**Data flow**: Hook fires → `build_rule_v2()` → JSONL log → `permissionsync-sync.sh` → `settings.json`

**Dual-target distinction**:
- `permissionsync-sync.sh` writes to `~/.claude/settings.json` (global, user-level)
- `permissionsync-worktree-sync.sh` writes to `<worktree>/.claude/settings.local.json` (per-project)
- `permissionsync-install.sh` / `permissionsync-setup.sh` write hook config to `~/.claude/settings.json`

## File Map

### Hook Scripts (wired verbatim in settings.json)

| File | Event | Role |
|------|-------|------|
| `permissionsync-log-permission.sh` | `PermissionRequest` | Logs requests + auto-approves safe/known/worktree rules |
| `permissionsync-log-permission-v1.sh` | `PermissionRequest` | Legacy: logs to JSONL, falls through to interactive prompt |
| `permissionsync-log-confirmed.sh` | `PostToolUse` | Logs confirmed (approved + executed) operations |
| `permissionsync-log-hook-errors.sh` | `PostToolUseFailure` | Logs failed tool executions |
| `permissionsync-watch-config.sh` | `ConfigChange` | Warns when permissionsync hooks are removed from settings |
| `permissionsync-sync-on-end.sh` | `SessionEnd` | Auto-runs `permissionsync-sync.sh --apply` on session exit |
| `permissionsync-session-start.sh` | `SessionStart` | Shows pending rule drift at session open |
| `permissionsync-worktree-create.sh` | `WorktreeCreate` | Seeds `settings.local.json` into new worktrees |

### Worker Scripts (called by hooks or dispatcher)

| File | Role |
|------|------|
| `permissionsync-sync.sh` | Reads JSONL log, deduplicates, merges into `~/.claude/settings.json` |
| `permissionsync-worktree-sync.sh` | Aggregates rules from sibling worktrees' `settings.local.json` |
| `permissionsync-settings.sh` | Outputs merged permissions JSON for `claude --settings` |
| `permissionsync-launch.sh` | Launches `claude -w` in a worktree with merged permissions |

### Installer / CLI Scripts

| File | Role |
|------|------|
| `permissionsync.sh` | Unified CLI dispatcher — delegates to workers and installers |
| `permissionsync-install.sh` | Standalone installer — copies scripts, configures hooks in settings.json |
| `permissionsync-setup.sh` | Nix-friendly idempotent installer — silent when nothing changes |

### Library Scripts (sourced only — NOT on PATH)

| File | Role |
|------|------|
| `lib/permissionsync-config.sh` | Data definitions: `get_safe_subcommands()`, `get_indirection_type()`, `is_blocklisted_binary()`, `is_shell_keyword()`, `get_pre_subcommand_flags()`, `get_alt_rule_prefixes()` |
| `lib/permissionsync-lib.sh` | Core logic: `peel_indirection()`, `build_rule_v2()`, `is_safe_subcommand()`, `has_subcommands()`, `is_in_worktree()`, `discover_worktrees()`, `read_sibling_rules()` |

### Test Files

| File | Tests |
|------|-------|
| `tests/test-classify.sh` | `is_safe_subcommand()` and `has_subcommands()` |
| `tests/test-build-rule.sh` | `build_rule_v2()` — rule generation for all tool types |
| `tests/test-peel-indirection.sh` | `peel_indirection()` — indirection wrapper stripping |
| `tests/test-log-permission-auto.sh` | Auto-approve hook behavior (safe subcommands, log replay) |
| `tests/test-install.sh` | `permissionsync-install.sh` — all modes, idempotency, backup creation |
| `tests/test-setup-hooks.sh` | `permissionsync-setup.sh` — idempotent Nix installer |
| `tests/test-worktree-discovery.sh` | `is_in_worktree()`, `discover_worktrees()`, `read_sibling_rules()` |
| `tests/test-worktree-auto.sh` | Worktree-mode auto-approve in `permissionsync-log-permission.sh` |
| `tests/test-worktree-sync.sh` | `permissionsync-worktree-sync.sh` — all flags (preview, apply, report, diff, refine, from-log) |

### Config Files

| File | Role |
|------|------|
| `flake.nix` | Nix flake — package, tests check, pre-commit check, devShell |
| `flake.lock` | Pinned flake inputs |
| `.envrc` | direnv — `use flake` for auto-loading devShell |

## Key Concepts

### Rule Generation

`build_rule_v2(TOOL_NAME, TOOL_INPUT_JSON)` converts a tool invocation into a permission rule string. For `Bash` tools, it extracts the binary and subcommand from the command string. For `Read`/`Write`/`Edit`/`MultiEdit`, it returns the bare tool name. For `WebFetch`, it extracts the domain. For `mcp__*` tools, it uses the tool name directly.

### Indirection Peeling

`peel_indirection(CMD_STRING)` strips wrapper commands before extracting the actual binary:

- **prefix** type: `sudo`, `nice`, `nohup`, `time`, `command` — strip word + flags
- **prefix_kv** type: `env` — strip word + KEY=VAL pairs + flags
- **shell_c** type: `bash -c`, `sh -c`, `zsh -c`, `dash -c` — strip wrapper + `-c`, unquote argument
- **xargs** type: `xargs` — strip word + flags

Max 10 iterations. Important: `bash script.sh` (no `-c`) is NOT treated as indirection.

### Safe Subcommand Detection

Each tracked binary defines read-only subcommands:

| Binary | Safe subcommands |
|--------|-----------------|
| `git` | status, log, diff, show, branch, tag, describe, rev-parse, remote, ls-files, ls-tree, cat-file, shortlog, reflog, blame, version, help |
| `cargo` | check, clippy, fmt, metadata, tree, read-manifest, pkgid, verify-project, version |
| `npm` | ls, list, outdated, view, info, pack, config, prefix, root |
| `nix` | log, show-derivation, path-info, store |
| `docker` | ps, images, inspect, logs, stats, top, version, info, events, history, port |
| `kubectl` | get, describe, logs, top, version, cluster-info, api-resources, api-versions, explain |
| `pip` | list, show, freeze, check |
| `brew` | list, info, search, outdated, deps, leaves, config |

### Auto-Approve Decision Cascade

The runtime decision order in `permissionsync-log-permission.sh`:

1. **Safe subcommand** -> immediate allow (always, no env var needed)
2. **Sibling worktree match** -> allow (if `CLAUDE_PERMISSION_WORKTREE=1`)
3. **Log history match** -> allow (if `CLAUDE_PERMISSION_AUTO=1`)
4. **Fall-through** -> interactive prompt

### Security Guards

These checks run before safe subcommand classification and prevent auto-approval:

- **SEC-01**: Shell metacharacters (`&&`, `||`, `|`, `;`) — could chain arbitrary commands
- **SEC-03**: I/O redirections (`>>`, `&>`, `<<<`, `2>`, `>`, `<`) — could write to arbitrary files
- **SEC-04**: Background operator `&` — could spawn background processes
- **SEC-08**: Multiline commands — second+ lines could contain arbitrary code
- **Blocklisted binaries**: shells/interpreters (`bash`, `python`, `ruby`, `node`, `eval`, `exec`, etc.)
- **Shell keywords**: `for`, `if`, `while`, `case`, etc.
- **Binary name validation**: must match `^[a-zA-Z0-9_.~/-]+$`

### Worktree Discovery

- `is_in_worktree()` — fast guard comparing `git rev-parse --git-dir` vs `--git-common-dir`. Returns early if not in a git repo or no worktrees exist.
- `discover_worktrees([EXCLUDE_CURRENT])` — parses `git worktree list --porcelain`. Skips bare repos and missing paths. Sets `WORKTREE_PATHS[]` and `WORKTREE_COUNT`.
- `read_sibling_rules()` — calls `discover_worktrees 1`, reads `.claude/settings.local.json` from each sibling, deduplicates with `sort -u`. Sets `SIBLING_RULES` and `SIBLING_RULE_COUNT`.

## Global Variable Contracts

Functions communicate via globals rather than stdout to avoid subshell overhead:

| Function | Sets |
|----------|------|
| `build_rule_v2()` | `RULE`, `BASE_COMMAND`, `IS_SAFE`, `PEELED_COMMAND`, `INDIRECTION_CHAIN` |
| `peel_indirection()` | `PEELED_COMMAND`, `INDIRECTION_CHAIN` |
| `discover_worktrees()` | `WORKTREE_PATHS[]`, `WORKTREE_COUNT` |
| `read_sibling_rules()` | `SIBLING_RULES`, `SIBLING_RULE_COUNT` |

## Running Tests

**Local:**
```bash
for t in tests/test-*.sh; do bash "$t"; done
```

**Nix:**
```bash
nix flake check    # runs tests + shellcheck + shfmt
```

Tests use TAP format with custom assertion helpers: `assert_eq`, `assert_rc`, `assert_contains`, `assert_safe`, `assert_not_safe`.

## Linting

```bash
shfmt -w -s *.sh lib/*.sh tests/*.sh    # -s is required (simplify mode)
shellcheck --exclude=SC1091 *.sh lib/*.sh tests/*.sh
```

The `-s` flag is mandatory — `cachix/git-hooks.nix` pre-commit hooks use `shfmt -w -l -s`, and without `-s` you'll get format mismatches. SC1091 is excluded because shellcheck can't follow dynamic `source` paths.

## Coding Conventions

- **Bash 3.2 compatible** — no associative arrays, no `declare -A` (macOS constraint)
- **Tabs** for indentation (shfmt default)
- **`set -euo pipefail`** in all scripts
- **TAP test format** — `ok N - description` / `not ok N - description`, exit 1 on any failure
- **Library sourcing**: `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` then `source "${PERMISSIONSYNC_LIB_DIR:-$SCRIPT_DIR/lib}/permissionsync-lib.sh"`; `PERMISSIONSYNC_LIB_DIR` is set by Nix `makeWrapper` to `$out/share/permissionsync-cc/lib`
- **Global variables for return values** — not stdout (avoids subshell overhead from `$(func)`)
- **Minimize subprocesses** — prefer Bash parameter expansion over `sed`/`awk`/`cut`
- **SC2001 suppressed** for `sed 's/^/prefix/'` patterns — can't use `${var//}` for per-line prefixes

## Security Invariants

These invariants must be preserved. Violating them creates privilege escalation or data loss risks:

- **Never** add destructive commands (`rm`, `mv`, `exec`, `eval`) to safe subcommand lists
- **Never** remove the metacharacter/redirection/multiline guards (SEC-01, SEC-03, SEC-04, SEC-08)
- **Never** change `>>` appends to `>` overwrites on the log file (data loss)
- **Never** bypass `is_blocklisted_binary()` — shells/interpreters as rule binaries allow arbitrary code
- **Never** increase the indirection peel limit beyond 10 without careful review

**Known limitations:**
- Environment variable injection after peeling (e.g. `env MALICIOUS=val safe-binary`) — the peeler strips env vars but can't validate their effects
- Git aliases — `git lg` might be aliased to something destructive; we classify based on the literal subcommand
- Wildcard breadth — `Bash(git push *)` matches `git push --force --delete origin main`

## Common Tasks

### Adding a safe subcommand to an existing binary

1. Edit `lib/permissionsync-config.sh` — add subcommand to the relevant `case` in `get_safe_subcommands()`
2. Add test cases in `tests/test-classify.sh` (both `assert_safe` and `assert_not_safe` for neighbors)
3. Run `bash tests/test-classify.sh && bash tests/test-build-rule.sh`

### Adding a new tracked binary

1. Edit `lib/permissionsync-config.sh` — add new `case` block in `get_safe_subcommands()`
2. Optionally add `get_pre_subcommand_flags()` and `get_alt_rule_prefixes()` entries
3. Add test cases in `tests/test-classify.sh` and `tests/test-build-rule.sh`
4. Run all tests: `for t in tests/test-*.sh; do bash "$t"; done`

### Adding a new indirection wrapper

1. Edit `lib/permissionsync-config.sh` — add to `get_indirection_type()` (choose type: prefix, prefix_kv, shell_c, xargs)
2. If the wrapper has flags that consume arguments, add to `get_indirection_flags_with_args()` in `lib/permissionsync-config.sh`
3. Add test cases in `tests/test-peel-indirection.sh`
4. Run `bash tests/test-peel-indirection.sh && bash tests/test-build-rule.sh`

### Adding a new tool type (non-Bash)

1. Edit `lib/permissionsync-lib.sh` — add a new `case` branch in `build_rule_v2()`
2. Add test cases in `tests/test-build-rule.sh`
3. Run `bash tests/test-build-rule.sh`

### Modifying the installer

Both `permissionsync-install.sh` and `permissionsync-setup.sh` share the same hook-wiring logic (the `jq` expression that manages `PermissionRequest` entries and the MANAGED_ eviction lists for old hook names). Changes to one usually need to be mirrored in the other.

1. Edit `permissionsync-install.sh` and/or `permissionsync-setup.sh`
2. Run `bash tests/test-install.sh && bash tests/test-setup-hooks.sh`

## Nix Integration

- `makeWrapper` wraps executable scripts with runtime deps (`jq`, `git`, `coreutils`, etc.) on PATH
- Library scripts (`lib/permissionsync-*.sh`) go to `$out/share/permissionsync-cc/lib/` — NOT `$out/bin/`
- Raw copies of all non-library scripts go to `$out/share/permissionsync-cc/` — used by `permissionsync-setup.sh` to `cp` into `~/.claude/hooks/`
- `PERMISSIONSYNC_SHARE_DIR` is patched via `sed` on `$out/bin/.permissionsync-setup.sh-wrapped` to point to `$out/share/permissionsync-cc/`
- `PERMISSIONSYNC_LIB_DIR` is set via `makeWrapper --set` to `$out/share/permissionsync-cc/lib` for all wrapped scripts that source the lib
- `mainProgram = "permissionsync-setup.sh"`
- **Files must be `git add`ed before Nix can see them** (common flake gotcha)
- `checks.pre-commit-check` runs shellcheck + shfmt via `cachix/git-hooks.nix`
- `checks.tests` runs all `tests/test-*.sh` files inside a Nix sandbox
