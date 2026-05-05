# Claude Launcher (`cld`)

Profile-based launcher for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Routes `CLAUDE_CONFIG_DIR` based on your current working directory, so each project/client gets isolated Claude configuration.

## How it works

1. You run `cld` from a project directory
2. The launcher checks `profiles.json` to find which profiles are allowed for that directory (prefix match)
3. If one match: auto-selects. If multiple: opens an fzf picker with a preview pane (description + last session time). If none: errors out.
4. If the directory is a git repo with 2+ worktrees (or `-w` is passed): opens a worktree picker
5. Sets `CLAUDE_CONFIG_DIR=~/.config/claude-code/<profile>`, optionally `cd`s into the selected worktree, and execs `claude`

## Files

| File | Purpose |
|---|---|
| `cld.sh` | Main entrypoint script |
| `profiles.json` | Profile-to-directory mappings (single source of truth) |
| `_cld` | Zsh completion function (auto-discovered via `fpath`) |

## Dependencies

- **jq** - JSON parsing (`/usr/bin/jq`)
- **fzf** - Interactive profile selection when multiple profiles match (`~/.local/share/nvim/site/pack/packer/start/fzf/bin/fzf`)
- **claude** - Claude Code CLI (`~/.local/bin/claude`)
- **zsh** - Shell (not bash-compatible)

## Setup

1. Create your config from the example:

```bash
cp profiles.example.json profiles.json
```

Edit `profiles.json` with your own profiles and directories.

2. Add the launcher directory to your `fpath` **before** `compinit` / oh-my-zsh is sourced in `~/.zshrc`:

```zsh
fpath=(~/.scripts/claude-launcher $fpath)
```

3. Add a shell function to call the launcher:

```zsh
cld() {
  ~/.scripts/claude-launcher/cld.sh "$@"
}
```

4. Reload your shell:

```bash
exec zsh
```

Completions are registered automatically via the `#compdef cld` header in `_cld` - no manual `compdef` needed. The completion function expects the project to live at `~/.scripts/claude-launcher/`.

## Configuration

Edit `profiles.json` to add or modify profiles:

```json
{
  "profiles": {
    "myprofile": {
      "directories": ["~/Workspace/MyProject", "~/other/path"],
      "description": "My project description"
    }
  }
}
```

- `directories`: list of allowed directory prefixes. `~` is expanded at runtime.
- Directory matching is prefix-based with a `/` guard (e.g. `~/.scripts` won't match `~/.scripts-other`).

## Usage

```bash
cld                        # Auto-select or fzf if multiple profiles match
cld personal               # Explicitly pick a profile
cld personal --continue    # Pass flags through to claude
cld -w                     # Force the worktree picker (even for single-worktree repos)
cld personal -w            # Explicit profile + forced worktree picker
```

## Worktree management

When you're in a git repo with 2+ worktrees, a worktree picker appears automatically after profile selection. Use `-w`/`--worktree` to force it even with just one worktree.

The picker shows all worktrees with their branch names and a preview pane (git status, recent commits, last Claude session). From it you can:

| Selection | Action |
|---|---|
| `[ ↩ Stay in current dir ]` | Launch Claude in `$PWD` unchanged |
| Any listed worktree | `cd` to it and launch Claude there |
| `[ + New worktree ]` | Pick a branch (or type a new one) — worktree created at `../repo-branch`, then launched |
| `[ - Remove worktree... ]` | Secondary picker to remove a linked worktree |

Pressing Escape in the worktree picker also falls through to launching in `$PWD`.

## Tab completion

Completions are context-aware — only profiles valid for your `$PWD` are offered:

```bash
cd ~/Workspace/Work && cld <TAB>       # offers: work
cd ~/Workspace/Personal && cld <TAB>   # offers: personal
cld --<TAB>                            # offers: --worktree, -w, plus claude flags
```

After the profile name, common `claude` flags are completed (`--model`, `--continue`, `--resume`, etc.).
