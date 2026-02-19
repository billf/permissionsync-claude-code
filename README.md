# permissionsync-claude-code

Centralized logging and sync of Claude Code permission approvals across all repositories and worktrees.

## The Problem

Every time you open Claude Code in a new worktree, repo, or session, you re-approve the same tools: `Bash(npm run *)`, `Bash(git *)`, `Write`, etc. These approvals are ephemeral — they live in the session or in per-project `settings.local.json` files scattered everywhere.

## The Solution

A `PermissionRequest` hook that:

1. **Logs every permission request** to a single JSONL file (`~/.claude/permission-approvals.jsonl`)
2. **Deduplicates and syncs** those approvals into your global `~/.claude/settings.json` on demand
3. **(Optional)** Auto-approves rules you've previously seen — including rules discovered from sibling git worktrees — eliminating repeat prompts entirely

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
| `~/.claude/hooks/log-permission.sh` | Logs every `PermissionRequest` to JSONL (passive) |
| `~/.claude/hooks/log-permission-auto.sh` | Same, but auto-approves known rules |
| `~/.claude/hooks/sync-permissions.sh` | Merges JSONL log into `~/.claude/settings.json` |
| `~/.claude/hooks/worktree-sync.sh` | Aggregates and syncs permission rules across git worktrees |
| `~/.claude/hooks/permissionsync-config.sh` | Data definitions: safe subcommands, indirection types, blocklists |
| `~/.claude/hooks/permissionsync-lib.sh` | Core library: rule building, indirection peeling, worktree discovery |

The installer adds a `PermissionRequest` hook entry to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/log-permission.sh"
          }
        ]
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

### Phase 3: Auto-approve (optional)

If you trust your accumulated log and want to skip repeat prompts:

```bash
./install.sh --auto
```

This sets `CLAUDE_PERMISSION_AUTO=1`, which makes the hook auto-approve any rule that already exists in the JSONL log. New, never-before-seen tool uses still fall through to the interactive prompt.

**Worktree mode** takes this further:

```bash
./install.sh --worktree
```

This sets both `CLAUDE_PERMISSION_WORKTREE=1` and `CLAUDE_PERMISSION_AUTO=1`, enabling three layers of auto-approval:

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

**Tracked binaries** with subcommand-level rules: `git`, `cargo`, `npm`, `nix`, `docker`, `kubectl`, `pip`, `brew`. For these, the strategy emits `Bash(<binary> <subcommand> *)` (e.g. `Bash(git commit *)`). For untracked binaries, it falls back to `Bash(<binary> *)`.

**Indirection peeling**: wrappers like `sudo`, `env`, `xargs`, `bash -c`, `nice`, `nohup`, `time`, and `command` are stripped before extracting the actual binary and subcommand. For example, `sudo -u root git status` produces `Bash(git status *)`.

**Safe subcommand auto-approval**: each tracked binary defines a curated list of read-only subcommands (e.g. `git status`, `git log`, `git diff`, `cargo check`, `npm ls`). These are approved immediately without requiring env vars or log history. Security guards block safe classification when shell metacharacters (`&&`, `||`, `|`, `;`), I/O redirections, background operators, multiline content, blocklisted binaries (shells/interpreters), or shell keywords are detected.

**Rule refinement** (`--refine`): replaces broad wildcard rules like `Bash(git *)` with fine-grained safe-subcommand rules like `Bash(git status *)`, `Bash(git log *)`, `Bash(git diff *)`, etc. This reduces blast radius — `Bash(git push *)` would match `git push --force`, but `Bash(git status *)` only matches read-only operations.

## CLI Reference

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

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_PERMISSION_LOG` | `~/.claude/permission-approvals.jsonl` | Override log path |
| `CLAUDE_PERMISSION_AUTO` | *(unset)* | Set to `1` to auto-approve previously-seen rules |
| `CLAUDE_PERMISSION_WORKTREE` | *(unset)* | Set to `1` to auto-approve sibling worktree rules |

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

> **WARNING**: In auto-approve mode, denied requests are also auto-approved in future sessions. The `PermissionRequest` hook fires when Claude *requests* permission, not after you approve — so the log cannot distinguish approvals from denials. Always review with `--preview` before enabling `--auto`.

> **WARNING**: In worktree mode, any `.claude/settings.local.json` in a sibling worktree contributes to auto-approve decisions. A rule approved in one worktree will be auto-approved across all worktrees of the same repo.

**Mitigations:**

- Use `--refine` to narrow broad rules. A rule like `Bash(git *)` matches everything including `git push --force`. Running `--refine` replaces it with read-only subcommand rules like `Bash(git status *)`, `Bash(git log *)`, etc. — reducing blast radius significantly.
- Wildcards are inherently broad: `Bash(git push *)` matches `git push --force --delete origin main`. Review your rules periodically with `--preview`.
- If you want finer-grained control (e.g., exact argument patterns instead of wildcard `*`), edit the JSONL or the generated `settings.json` after sync.
- Hook config changes require a session restart to take effect per Claude Code's security model.
