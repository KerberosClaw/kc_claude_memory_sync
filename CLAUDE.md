# Claude Code Automation Guide

This file helps Claude Code automatically set up memory sync for the user.

## When the user asks to set up memory sync

1. Check if `config.sh` exists in this project directory.
2. If not, determine which setup mode to use:
   - **First machine** (no existing repo): run `./setup.sh init`
   - **Additional machine** (joining existing repo): run `./setup.sh join`
3. Both commands support non-interactive mode via CLI args:
   ```bash
   ./setup.sh init --repo-name kc_claude_memory --local-repo ~/dev/kc_claude_memory
   ./setup.sh join --repo-url https://github.com/user/repo.git --key-file /tmp/key --local-repo ~/dev/kc_claude_memory
   ```

## Prerequisites to verify

Before running setup, verify:
- `git` is installed
- `git-crypt` is installed: `which git-crypt`
- `jq` is installed: `which jq`
- `gh` (GitHub CLI) is installed and authenticated: `gh auth status`

## How it works

- `init` creates a GitHub private repo, initializes git-crypt, exports the encryption key, and pushes
- `join` clones the repo and unlocks it with a git-crypt key file
- Both configure `autoMemoryDirectory` in `~/.claude/settings.json` so Claude Code reads/writes memory from the synced repo
- A PostToolUse hook auto-commits and pushes on every Write/Edit to memory files

## After setup

- Verify settings: `jq '.autoMemoryDirectory' ~/.claude/settings.json`
- Check sync status: `./sync.sh status`
- Test the hook by writing a memory file and checking if it auto-commits

## Key management

- The git-crypt key is at `<local-repo>/.git/git-crypt-key` after init
- Transfer it securely to other machines (scp, USB, AirDrop)
- Lose the key = lose access to encrypted memory on GitHub
- Delete key copies from transfer locations after setup

## Troubleshooting

- If push fails silently, check `./sync.sh status`
- If hook doesn't trigger, verify `~/.claude/settings.json` has the PostToolUse hook
- If files look encrypted, run `git-crypt unlock <key-file>` in the repo
