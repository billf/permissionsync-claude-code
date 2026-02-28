# permissionsync-claude-code

Centralized logging and sync of Claude Code permission approvals across all repositories and worktrees.

## The Problem

Every time you open Claude Code in a new worktree, repo, or session, you re-approve the same tools: `Bash(npm run *)`, `Bash(git *)`, `Write`, etc. These approvals are ephemeral — they live in the session or in per-project `settings.local.json` files scattered everywhere.

## The Solution

Five hooks that together:

1. **Log every permission request** to a single JSONL file (`~/.claude/permission-approvals.jsonl`)
2. **Record confirmed approvals** separately in `confirmed-approvals.jsonl` (tools that actually executed)
3. **Capture tool failures** in `hook-errors.jsonl` for a complete audit trilogy
4. **Auto-sync rules** on session exit — no manual `sync --apply` needed
5. **(Optional)** Auto-approve rules you've previously seen, including sibling worktree rules

## Requirements

- `jq` (available via `brew install jq`, `apt install jq`, etc.)
- `bash` 3.2+ (macOS default is sufficient)
- `git` (only required for worktree features)
- Claude Code >= 2.0.45 (for `PermissionRequest` hook support)

## Install

### Nix Flake

Add as a flake input and call `setup-hooks.sh` from your devShell's `shellHook`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    permissionsync-cc.url = "github:billf/permissionsync-claude-code";
    permissionsync-cc.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, permissionsync-cc, ... }:
    let
      system = "aarch64-darwin"; # adjust for your system
      pkgs = nixpkgs.legacyPackages.${system};
      psc = permissionsync-cc.packages.${system}.default;
    in {
      devShells.${system}.default = pkgs.mkShell {
        shellHook = ''
          ${psc}/bin/setup-hooks.sh            # log-only (default)
          # ${psc}/bin/setup-hooks.sh auto      # auto-approve mode
          # ${psc}/bin/setup-hooks.sh worktree  # auto-approve + sibling worktree rules
        '';
      };
    };
}
```

The setup script is idempotent and silent — it only copies files when they've changed and skips settings.json when the hook entry already exists.

An overlay is also available at `permissionsync-cc.overlays.default` if you prefer `pkgs.permissionsync-cc`.

### Manual (no Nix)

```bash
git clone https://github.com/billf/permissionsync-claude-code.git && cd permissionsync-claude-code
./install.sh              # log-only mode
# or
./install.sh --auto       # auto-approve previously-seen rules
# or
./install.sh --worktree   # auto-approve + sibling worktree rules
```

## What gets installed

| File | Purpose |
|------|---------|
| `~/.claude/hooks/log-permission-auto.sh` | `PermissionRequest` hook — logs requests, optionally auto-approves |
| `~/.claude/hooks/log-confirmed.sh` | `PostToolUse` hook — logs confirmed (approved + executed) operations |
| `~/.claude/hooks/permissionsync-log-hook-errors.sh` | `PostToolUseFailure` hook — logs failed tool executions |
| `~/.claude/hooks/permissionsync-watch-config.sh` | `ConfigChange` hook — warns when permissionsync hooks are removed from settings |
| `~/.claude/hooks/permissionsync-sync-on-end.sh` | `SessionEnd` hook — auto-runs `sync --apply` on session exit |
| `~/.claude/hooks/sync-permissions.sh` | Merges JSONL log into `~/.claude/settings.json` |
| `~/.claude/hooks/worktree-sync.sh` | Aggregates and syncs permission rules across git worktrees |
| `~/.claude/hooks/merged-settings.sh` | Outputs merged permissions JSON for `claude --settings` |
| `~/.claude/hooks/permissionsync-launch.sh` | Launches claude in a worktree with merged permissions |
| `~/.claude/hooks/permissionsync.sh` | Unified CLI dispatcher for all subcommands |
| `~/.claude/hooks/permissionsync-config.sh` | Data definitions: safe subcommands, indirection types, blocklists |
| `~/.claude/hooks/permissionsync-lib.sh` | Core library: rule building, indirection peeling, worktree discovery |

The installer wires five hooks into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "CLAUDE_PERMISSION_MODE=log ~/.claude/hooks/log-permission-auto.sh"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "~/.claude/hooks/log-confirmed.sh"}]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "~/.claude/hooks/permissionsync-log-hook-errors.sh"}]
      }
    ],
    "ConfigChange": [
      {
        "matcher": "user_settings",
        "hooks": [{"type": "command", "command": "~/.claude/hooks/permissionsync-watch-config.sh"}]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "~/.claude/hooks/permissionsync-sync-on-end.sh"}]
      }
    ]
  }
}
```

## Workflow

### Phase 1: Collect (automatic)

Just use Claude Code normally. Every time you see a permission prompt and approve it, the hook logs:

```jsonl
{"timestamp":"2026-02-06T15:30:00Z","tool":"Bash","rule":"Bash(npm run *)","cwd":"/home/you/project-a"}
{"timestamp":"2026-02-06T15:31:00Z","tool":"Bash","rule":"Bash(git status *)","cwd":"/home/you/project-b"}
{"timestamp":"2026-02-06T15:32:00Z","tool":"Write","rule":"Write","cwd":"/home/you/project-a"}
```

A second log, `~/.claude/confirmed-approvals.jsonl`, is written by the `PostToolUse` hook. Unlike the request log (which captures all prompts including denied ones), the confirmed log only records tools that actually executed — giving a clean record of truly approved operations. Use `--from-confirmed` with `sync-permissions.sh` to sync only from confirmed approvals.

### Audit Trilogy & Lifecycle Hooks

Three complementary logs build a complete audit trail of every tool interaction:

| Log file | Written by | What it captures |
|----------|-----------|-----------------|
| `~/.claude/permission-approvals.jsonl` | `PermissionRequest` hook | Every tool prompt — approved and denied |
| `~/.claude/confirmed-approvals.jsonl` | `PostToolUse` hook | Tools that executed successfully (clean approved signal) |
| `~/.claude/hook-errors.jsonl` | `PostToolUseFailure` hook | Tools that failed — tool name, rule, error code, error message |

Together these give you *requested*, *approved*, and *failed* in three separate streams, each queryable with `jq`.

Two additional lifecycle hooks run automatically:

**`ConfigChange` → `~/.claude/config-changes.jsonl`**

Fires whenever `~/.claude/settings.json` is written. Checks whether permissionsync's hooks are still present and logs the result:

```json
{"timestamp":"...","source":"user_settings","file_path":"~/.claude/settings.json","hooks_intact":true}
```

If the hooks were removed, prints a warning to stderr and logs `hooks_intact: false`. Re-run `install.sh` to restore them.

**`SessionEnd` → auto-sync**

When a session ends, `permissionsync-sync-on-end.sh` automatically runs `sync-permissions.sh --apply`. Rules accumulated during the session are promoted to `~/.claude/settings.json` without any manual step. The next session starts with those rules already present.

### Phase 2: Review & sync (on demand)

```bash
# See what would be added
~/.claude/hooks/sync-permissions.sh --preview

# === Current rules in ~/.claude/settings.json ===
#   Bash(git status *)
#
# === New rules from approval log ===
#   + Bash(npm run *)
#   + Write
#
# === Merged result ===
# ["Bash(git status *)", "Bash(npm run *)", "Write"]

# Apply
~/.claude/hooks/sync-permissions.sh --apply

# Just dump the merged array (for piping/scripting)
~/.claude/hooks/sync-permissions.sh --print

# Show diff between current settings and proposed merge
~/.claude/hooks/sync-permissions.sh --diff

# Propose replacing broad rules with fine-grained safe-subcommand rules
~/.claude/hooks/sync-permissions.sh --refine

# Apply refined rules
~/.claude/hooks/sync-permissions.sh --refine --apply

# Sync from confirmed-approvals log (approved + executed ops only)
~/.claude/hooks/sync-permissions.sh --from-confirmed --preview
~/.claude/hooks/sync-permissions.sh --from-confirmed --apply
```

### Phase 2b: Cross-worktree sync

If you use git worktrees, `worktree-sync.sh` aggregates permission rules from all sibling worktrees' `.claude/settings.local.json` files into a shared superset:

```bash
# Preview: show all worktrees, rule counts, and aggregated superset
~/.claude/hooks/worktree-sync.sh --preview

# Show which rules appear in how many worktrees
~/.claude/hooks/worktree-sync.sh --report

# Diff current worktree's rules vs the aggregated superset
~/.claude/hooks/worktree-sync.sh --diff

# Write aggregated rules to current worktree's settings.local.json
~/.claude/hooks/worktree-sync.sh --apply

# Write aggregated rules to ALL worktrees
~/.claude/hooks/worktree-sync.sh --apply-all

# Also include rules from the JSONL approval log (scoped to worktree CWDs)
~/.claude/hooks/worktree-sync.sh --from-log --preview

# Replace broad rules with safe-subcommand expansions
~/.claude/hooks/worktree-sync.sh --refine
~/.claude/hooks/worktree-sync.sh --refine --apply
~/.claude/hooks/worktree-sync.sh --refine --apply-all
```

### Worktree Launch Integration (`claude --worktree`)

Claude Code's `claude --worktree` (`-w`) starts sessions in isolated git worktrees at `<repo>/.claude/worktrees/<name>`. Combined with `--settings`, you can launch a worktree pre-loaded with permissions from all sibling worktrees and global settings — no re-approval needed.

**How it works:** `--settings <path>` layers additional settings on top of the normal hierarchy. Using bash process substitution, `merged-settings.sh` generates the JSON on the fly:

```bash
# Launch a worktree with merged permissions from all sources
claude -w feature-x --settings <(~/.claude/hooks/merged-settings.sh)

# Same, but refine broad rules (e.g. Bash(git *)) into safe subcommands
claude -w feature-x --settings <(~/.claude/hooks/merged-settings.sh --refine)

# Also include rules from the JSONL approval log
claude -w feature-x --settings <(~/.claude/hooks/merged-settings.sh --refine --from-log)

# Global settings only (no worktree rule discovery)
claude -w feature-x --settings <(~/.claude/hooks/merged-settings.sh --global-only)
```

**Using `permissionsync-launch.sh` (simpler — no process substitution):**
```bash
~/.claude/hooks/permissionsync-launch.sh feature-x              # merged + refined
~/.claude/hooks/permissionsync-launch.sh --from-log feature-x   # also include JSONL log rules
~/.claude/hooks/permissionsync-launch.sh --dry-run feature-x    # print equivalent command
~/.claude/hooks/permissionsync-launch.sh feature-x -- --resume <id>  # extra claude args
```

Or via the unified CLI:
```bash
~/.claude/hooks/permissionsync.sh launch feature-x
```

**Shell alias for convenience:**
```bash
# .bashrc / .zshrc
alias cw='~/.claude/hooks/permissionsync-launch.sh'
```

Then just: `cw feature-x`

### Phase 3: Auto-approve (optional)

If you trust your accumulated log and want to skip repeat prompts:

```bash
./install.sh --auto
```

This sets `CLAUDE_PERMISSION_MODE=auto`, which makes the hook auto-approve any rule that already exists in the JSONL log. New, never-before-seen tool uses still fall through to the interactive prompt.

**Worktree mode** takes this further:

```bash
./install.sh --worktree
```

This sets `CLAUDE_PERMISSION_MODE=worktree`, enabling three layers of auto-approval:

1. **Safe subcommand auto-approval** — read-only operations like `git status`, `cargo check`, `npm list` are always approved immediately (no env var needed)
2. **Sibling worktree matching** — if any sibling worktree's `.claude/settings.local.json` already contains a rule, it's approved
3. **Log history matching** — if the JSONL log contains the rule from a previous session, it's approved

Re-running `install.sh` with a different flag switches modes (idempotent — creates a `.bak` backup of settings.json).

## How rules are generated

| Tool | Input field | Generated rule |
|------|------------|----------------|
| `Bash` | `command: "npm run test"` | `Bash(npm run *)` |
| `Bash` | `command: "git commit -m 'fix'"` | `Bash(git commit *)` |
| `Bash` | `command: "cat file.txt"` | `Bash(cat *)` |
| `Read` / `Write` / `Edit` | `file_path: ...` | `Read` / `Write` / `Edit` |
| `WebFetch` | `url: "https://docs.anthropic.com/..."` | `WebFetch(domain:docs.anthropic.com)` |
| `mcp__*` | — | `mcp__server__tool` (exact) |

**Tracked binaries** with subcommand-level rules: `git`, `cargo`, `npm`, `nix`, `docker`, `kubectl`, `pip`, `brew`, `gh`, `rustup`, `yarn`, `pnpm`, `jj`, `terraform`. For these, the strategy emits `Bash(<binary> <subcommand> *)` (e.g. `Bash(git commit *)`). For untracked binaries, it falls back to `Bash(<binary> *)`.

**Always-safe binaries**: `fd`, `rg`, `bat`, `delta`, `difftastic` — read-only tools that are automatically classified `IS_SAFE=true` regardless of arguments (subject to metacharacter guards). Broad rules like `Bash(rg *)` are approved immediately.

**Indirection peeling**: wrappers like `sudo`, `env`, `xargs`, `bash -c`, `nice`, `nohup`, `time`, and `command` are stripped before extracting the actual binary and subcommand. For example, `sudo -u root git status` produces `Bash(git status *)`.

**Safe subcommand auto-approval**: each tracked binary defines a curated list of read-only subcommands (e.g. `git status`, `git log`, `git diff`, `cargo check`, `npm ls`). These are approved immediately without requiring env vars or log history. Security guards block safe classification when shell metacharacters (`&&`, `||`, `|`, `;`), I/O redirections, background operators, multiline content, blocklisted binaries (shells/interpreters), or shell keywords are detected.

**Rule refinement** (`--refine`): replaces broad wildcard rules like `Bash(git *)` with fine-grained safe-subcommand rules like `Bash(git status *)`, `Bash(git log *)`, `Bash(git diff *)`, etc. This reduces blast radius — `Bash(git push *)` would match `git push --force`, but `Bash(git status *)` only matches read-only operations.

## CLI Reference

### permissionsync.sh (unified CLI)

Single entry point that delegates to the individual scripts:

```bash
~/.claude/hooks/permissionsync.sh sync [FLAGS]        # sync-permissions.sh
~/.claude/hooks/permissionsync.sh worktree [FLAGS]    # worktree-sync.sh
~/.claude/hooks/permissionsync.sh settings [FLAGS]    # merged-settings.sh
~/.claude/hooks/permissionsync.sh launch [FLAGS] <name>  # permissionsync-launch.sh
~/.claude/hooks/permissionsync.sh install [--mode=log|auto|worktree]  # install.sh
~/.claude/hooks/permissionsync.sh status              # show hooks, rule counts, log state
```

### sync-permissions.sh

Reads the JSONL approval log and merges rules into `~/.claude/settings.json` (global, user-level).

| Flag | Description |
|------|-------------|
| *(no flag)* | Same as `--preview` |
| `--preview` | Show current rules, new rules from log, and merged result |
| `--apply` | Write merged rules to `~/.claude/settings.json` (creates `.bak`) |
| `--print` | Print deduplicated rules as JSON array (for piping) |
| `--diff` | Show diff between current settings and proposed merge |
| `--refine` | Propose replacing broad rules with fine-grained safe-subcommand rules |
| `--refine --apply` | Write refined rules to `~/.claude/settings.json` |
| `--from-confirmed` | Use `confirmed-approvals.jsonl` as source (approved ops only) |
| `--init-base` | Preview baseline safe-subcommand rules (from `base-settings.json`) |
| `--init-base --apply` | Seed baseline rules into `~/.claude/settings.json` |

### worktree-sync.sh

Aggregates rules from sibling worktrees' `.claude/settings.local.json` files (per-project).

| Flag | Description |
|------|-------------|
| *(no flag)* | Same as `--preview` |
| `--preview` | Show all worktrees, rule counts, aggregated superset |
| `--apply` | Write aggregated rules to current worktree's `settings.local.json` |
| `--apply-all` | Write aggregated rules to ALL worktrees |
| `--report` | Show rule frequency across worktrees |
| `--diff` | Diff current worktree rules vs aggregated superset |
| `--refine` | Replace broad rules with safe-subcommand expansions |
| `--refine --apply` | Refine + write to current worktree |
| `--refine --apply-all` | Refine + write to all worktrees |
| `--from-log` | Also include rules from the JSONL approval log (scoped to worktree CWDs) |

### merged-settings.sh

Outputs a complete `{"permissions":{"allow":[...],"deny":[...]}}` JSON document to stdout. Designed for `claude --settings <(merged-settings.sh)`.

| Flag | Description |
|------|-------------|
| *(no flag)* | Same as `--merged` |
| `--merged` | Merge global settings + all worktree rules |
| `--refine` | Also apply safe-subcommand refinement to broad rules |
| `--from-log` | Also include rules from JSONL approval log |
| `--global-only` | Skip worktree discovery, use global settings only |

All diagnostic output goes to stderr. stdout is pure JSON only.

### permissionsync-launch.sh

Launches `claude` in a new worktree with merged permissions. Generates a temp settings file from `merged-settings.sh` and passes it via `--settings`.

| Flag | Description |
|------|-------------|
| `<name>` | Worktree name (required) |
| `--from-log` | Also include JSONL approval log rules |
| `--global-only` | Skip sibling worktree discovery |
| `--no-refine` | Skip safe-subcommand refinement |
| `--dry-run` | Print the equivalent command without executing |
| `-- ARGS` | Extra arguments passed through to `claude` |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_PERMISSION_LOG` | `~/.claude/permission-approvals.jsonl` | Override log path |
| `CLAUDE_PERMISSION_MODE` | `log` | Hook mode: `log` (log only), `auto` (auto-approve from history), `worktree` (auto-approve + sibling worktrees) |

Legacy aliases (still supported): `CLAUDE_PERMISSION_AUTO=1` (→ `auto` mode), `CLAUDE_PERMISSION_WORKTREE=1` (→ `worktree` mode).

## Tips

**Shell alias for quick sync:**
```bash
# .bashrc / .zshrc
alias claude-sync-perms='~/.claude/hooks/sync-permissions.sh'
alias claude-perms-preview='~/.claude/hooks/sync-permissions.sh --preview'
```

**View the raw log:**
```bash
cat ~/.claude/permission-approvals.jsonl | jq .
```

**Filter by repo:**
```bash
jq 'select(.cwd | contains("my-project"))' ~/.claude/permission-approvals.jsonl
```

**Reset the log:**
```bash
rm ~/.claude/permission-approvals.jsonl
```

**Generate project-specific settings** from the global log:
```bash
jq -r 'select(.cwd | contains("/path/to/project")) | .rule' \
  ~/.claude/permission-approvals.jsonl | sort -u | \
  jq -R -s 'split("\n") | map(select(length > 0))'
```

## Security Considerations

> **NOTE on the request log**: The `PermissionRequest` hook fires when Claude *requests* permission, not after you respond. The request log (`permission-approvals.jsonl`) therefore captures all prompts including ones you denied. For a clean record of approved-and-executed operations, use the confirmed log (`confirmed-approvals.jsonl`) written by the `PostToolUse` hook. Run `sync-permissions.sh --from-confirmed` to sync only from confirmed approvals.

> **WARNING**: In worktree mode, any `.claude/settings.local.json` in a sibling worktree contributes to auto-approve decisions. A rule approved in one worktree will be auto-approved across all worktrees of the same repo.

**Mitigations:**

- Use `--refine` to narrow broad rules. A rule like `Bash(git *)` matches everything including `git push --force`. Running `--refine` replaces it with read-only subcommand rules like `Bash(git status *)`, `Bash(git log *)`, etc. — reducing blast radius significantly.
- Wildcards are inherently broad: `Bash(git push *)` matches `git push --force --delete origin main`. Review your rules periodically with `--preview`.
- If you want finer-grained control (e.g., exact argument patterns instead of wildcard `*`), edit the JSONL or the generated `settings.json` after sync.
- Hook config changes require a session restart to take effect per Claude Code's security model.
