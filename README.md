# claude-permission-logger

Centralized logging and sync of Claude Code permission approvals across all repositories and worktrees.

## The Problem

Every time you open Claude Code in a new worktree, repo, or session, you re-approve the same tools: `Bash(npm run *)`, `Bash(git *)`, `Write`, etc. These approvals are ephemeral — they live in the session or in per-project `settings.local.json` files scattered everywhere.

## The Solution

A `PermissionRequest` hook that:

1. **Logs every permission request** to a single JSONL file (`~/.claude/permission-approvals.jsonl`)
2. **Deduplicates and syncs** those approvals into your global `~/.claude/settings.json` on demand
3. **(Optional)** Auto-approves rules you've previously seen, eliminating repeat prompts entirely

## Install

### Nix Flake

Add as a flake input and call `setup-hooks.sh` from your devShell's `shellHook`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    permissionsync-cc.url = "github:billf/permissionsync-cc";
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
          ${psc}/bin/setup-hooks.sh      # log-only (default)
          # ${psc}/bin/setup-hooks.sh auto  # auto-approve mode
        '';
      };
    };
}
```

The setup script is idempotent and silent — it only copies files when they've changed and skips settings.json when the hook entry already exists.

An overlay is also available at `permissionsync-cc.overlays.default` if you prefer `pkgs.permissionsync-cc`.

### Manual (no Nix)

```bash
git clone <this-repo> && cd claude-permission-logger
./install.sh          # log-only mode
# or
./install.sh --auto   # auto-approve previously-seen rules
```

## What gets installed

| File | Purpose |
|------|---------|
| `~/.claude/hooks/log-permission.sh` | Logs every `PermissionRequest` to JSONL (passive) |
| `~/.claude/hooks/log-permission-auto.sh` | Same, but auto-approves known rules |
| `~/.claude/hooks/sync-permissions.sh` | Merges JSONL log into `~/.claude/settings.json` |

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
```

### Phase 3: Auto-approve (optional)

If you trust your accumulated log and want to skip repeat prompts:

```bash
./install.sh --auto
```

This sets `CLAUDE_PERMISSION_AUTO=1`, which makes the hook auto-approve any rule that already exists in the JSONL log. New, never-before-seen tool uses still fall through to the interactive prompt.

## How rules are generated

| Tool | Input field | Generated rule |
|------|------------|----------------|
| `Bash` | `command: "npm run test"` | `Bash(npm run *)` |
| `Bash` | `command: "git commit -m 'fix'"` | `Bash(git commit *)` |
| `Bash` | `command: "cat file.txt"` | `Bash(cat *)` |
| `Read` / `Write` / `Edit` | `file_path: ...` | `Read` / `Write` / `Edit` |
| `WebFetch` | `url: "https://docs.anthropic.com/..."` | `WebFetch(domain:docs.anthropic.com)` |
| `mcp__*` | — | `mcp__server__tool` (exact) |

For tracked multi-subcommand tools (`git`, `cargo`, `npm`, `nix`, etc.), the strategy emits `Bash(<binary> <subcommand> *)`. For untracked tools, it falls back to `Bash(<binary> *)`. Indirection wrappers like `sudo`, `env`, `xargs`, and `bash -c` are peeled before extraction. You can always edit `~/.claude/settings.json` after sync to tighten or loosen rules.

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

## Requirements

- `jq` (available via `brew install jq`, `apt install jq`, etc.)
- Claude Code ≥ 2.0.45 (for `PermissionRequest` hook support)

## Caveats

- The `PermissionRequest` hook fires when Claude *requests* permission, not after you approve. In log-only mode this means you'll log requests you *deny* too. The sync script doesn't distinguish — review with `--preview` before `--apply`.
- If you want finer-grained control (e.g., exact argument patterns instead of wildcard `*`), edit the JSONL or the generated `settings.json` after sync.
- Hook config changes require a session restart to take effect per Claude Code's security model.
