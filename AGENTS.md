# AGENTS.md — permissionsync-cc

## Repository Purpose

Pure Bash toolkit for Claude Code's `PermissionRequest` hook system. Logs every tool-permission request to a JSONL file, builds deduplicated permission rules, syncs them into `~/.claude/settings.json` or per-project `settings.local.json`, and optionally auto-approves previously seen or worktree-shared rules. All scripts target Bash 3.2+ (macOS default) — no associative arrays.

## Architecture

```
permissionsync-config.sh  (data: safe subcommand tables, indirection types, blocklists)
  <- permissionsync-lib.sh  (logic: rule building, indirection peeling, worktree discovery)
    <- log-permission.sh         (hook: log-only)
    <- log-permission-auto.sh    (hook: log + auto-approve)
    <- sync-permissions.sh       (CLI: log -> settings.json)
    <- worktree-sync.sh          (CLI: worktree settings.local.json aggregation)

install.sh       (standalone installer, copies scripts + configures hook)
setup-hooks.sh   (idempotent installer for Nix flake shellHooks)
```

**Data flow**: Hook fires -> `build_rule_v2()` -> JSONL log -> `sync-permissions.sh` -> `settings.json`

**Dual-target distinction**:
- `sync-permissions.sh` writes to `~/.claude/settings.json` (global, user-level)
- `worktree-sync.sh` writes to `<worktree>/.claude/settings.local.json` (per-project)
- `install.sh` / `setup-hooks.sh` write hook config to `~/.claude/settings.json`

## File Map

### Executable Scripts

| File | Role |
|------|------|
| `log-permission.sh` | PermissionRequest hook — logs to JSONL, falls through to interactive prompt |
| `log-permission-auto.sh` | PermissionRequest hook — logs + auto-approves safe/known/worktree rules |
| `sync-permissions.sh` | CLI — reads JSONL log, deduplicates, merges into `~/.claude/settings.json` |
| `worktree-sync.sh` | CLI — aggregates rules from sibling worktrees' `settings.local.json` |
| `install.sh` | Standalone installer — copies scripts, configures hook in settings.json |
| `setup-hooks.sh` | Nix-friendly idempotent installer — silent when nothing changes |

### Library Scripts

| File | Role |
|------|------|
| `permissionsync-config.sh` | Data definitions: `get_safe_subcommands()`, `get_indirection_type()`, `is_blocklisted_binary()`, `is_shell_keyword()`, `get_pre_subcommand_flags()`, `get_alt_rule_prefixes()` |
| `permissionsync-lib.sh` | Core logic: `peel_indirection()`, `build_rule_v2()`, `is_safe_subcommand()`, `has_subcommands()`, `is_in_worktree()`, `discover_worktrees()`, `read_sibling_rules()` |

### Test Files

| File | Tests |
|------|-------|
| `tests/test-classify.sh` | `is_safe_subcommand()` and `has_subcommands()` |
| `tests/test-build-rule.sh` | `build_rule_v2()` — rule generation for all tool types |
| `tests/test-peel-indirection.sh` | `peel_indirection()` — indirection wrapper stripping |
| `tests/test-log-permission-auto.sh` | Auto-approve hook behavior (safe subcommands, log replay) |
| `tests/test-install.sh` | `install.sh` — all modes, idempotency, backup creation |
| `tests/test-setup-hooks.sh` | `setup-hooks.sh` — idempotent Nix installer |
| `tests/test-worktree-discovery.sh` | `is_in_worktree()`, `discover_worktrees()`, `read_sibling_rules()` |
| `tests/test-worktree-auto.sh` | Worktree-mode auto-approve in `log-permission-auto.sh` |
| `tests/test-worktree-sync.sh` | `worktree-sync.sh` — all flags (preview, apply, report, diff, refine, from-log) |

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

The runtime decision order in `log-permission-auto.sh`:

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
shfmt -w -s *.sh tests/*.sh    # -s is required (simplify mode)
shellcheck --exclude=SC1091 *.sh tests/*.sh
```

The `-s` flag is mandatory — `cachix/git-hooks.nix` pre-commit hooks use `shfmt -w -l -s`, and without `-s` you'll get format mismatches. SC1091 is excluded because shellcheck can't follow dynamic `source` paths.

## Coding Conventions

- **Bash 3.2 compatible** — no associative arrays, no `declare -A` (macOS constraint)
- **Tabs** for indentation (shfmt default)
- **`set -euo pipefail`** in all scripts
- **TAP test format** — `ok N - description` / `not ok N - description`, exit 1 on any failure
- **Library sourcing**: `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` then `source "${SCRIPT_DIR}/permissionsync-lib.sh"`
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

1. Edit `permissionsync-config.sh` — add subcommand to the relevant `case` in `get_safe_subcommands()`
2. Add test cases in `tests/test-classify.sh` (both `assert_safe` and `assert_not_safe` for neighbors)
3. Run `bash tests/test-classify.sh && bash tests/test-build-rule.sh`

### Adding a new tracked binary

1. Edit `permissionsync-config.sh` — add new `case` block in `get_safe_subcommands()`
2. Optionally add `get_pre_subcommand_flags()` and `get_alt_rule_prefixes()` entries
3. Add test cases in `tests/test-classify.sh` and `tests/test-build-rule.sh`
4. Run all tests: `for t in tests/test-*.sh; do bash "$t"; done`

### Adding a new indirection wrapper

1. Edit `permissionsync-config.sh` — add to `get_indirection_type()` (choose type: prefix, prefix_kv, shell_c, xargs)
2. If the wrapper has flags that consume arguments, add to `get_indirection_flags_with_args()`
3. Add test cases in `tests/test-peel-indirection.sh`
4. Run `bash tests/test-peel-indirection.sh && bash tests/test-build-rule.sh`

### Adding a new tool type (non-Bash)

1. Edit `permissionsync-lib.sh` — add a new `case` branch in `build_rule_v2()`
2. Add test cases in `tests/test-build-rule.sh`
3. Run `bash tests/test-build-rule.sh`

### Modifying the installer

Both `install.sh` and `setup-hooks.sh` share the same hook-wiring logic (the `jq` expression that manages `PermissionRequest` entries). Changes to one usually need to be mirrored in the other.

1. Edit `install.sh` and/or `setup-hooks.sh`
2. Run `bash tests/test-install.sh && bash tests/test-setup-hooks.sh`

## Nix Integration

- `makeWrapper` wraps executable scripts with runtime deps (`jq`, `git`, `coreutils`, etc.) on PATH
- Library scripts are copied to `$out/bin/` UNwrapped (they get `source`'d, not exec'd)
- Raw copies of ALL scripts go to `$out/share/permissionsync-cc/` — used by `setup-hooks.sh` to `cp` into `~/.claude/hooks/`
- `PERMISSIONSYNC_SHARE_DIR` is patched via `sed` on `$out/bin/.setup-hooks.sh-wrapped` to point to `$out/share/permissionsync-cc/`
- **Files must be `git add`ed before Nix can see them** (common flake gotcha)
- `checks.pre-commit-check` runs shellcheck + shfmt via `cachix/git-hooks.nix`
- `checks.tests` runs all `tests/test-*.sh` files inside a Nix sandbox
