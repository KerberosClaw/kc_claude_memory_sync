# Claude Code Automation Guide

This file helps Claude Code automatically set up memory sync for the user.

## When the user asks to set up memory sync

1. Check if `config.yaml` exists in this project directory.
2. If not, ask the user for:
   - Hub machine SSH host (IP or hostname)
   - Hub machine SSH username
   - (Optional) Bare repo path, SSH key path, local repo path — use defaults if not specified
3. Write `config.yaml` using the format in `config.example.yaml`.
4. Determine which setup mode to use:
   - If this machine IS the hub (the user says so, or the host matches this machine): run `./setup.sh init-hub`
   - If this machine is a spoke (connecting to an existing hub): run `./setup.sh join`
5. Both commands support non-interactive mode via CLI args:
   ```bash
   ./setup.sh init-hub --hub-host HOST --hub-user USER
   ./setup.sh join --hub-host HOST --hub-user USER
   ```

## Prerequisites to verify

Before running setup, verify:
- `jq` is installed: `which jq`
- SSH key exists: `ls ~/.ssh/id_ed25519`
- Passwordless SSH works: `ssh -o BatchMode=yes USER@HOST true`

If passwordless SSH is not set up, guide the user:
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub USER@HOST
```

## After setup

- Verify the symlink: `ls -la ~/.claude/projects/-Users-$(whoami)/memory`
- Check sync status: `~/dev/claude-memory/.sync.sh status`
- Test the hook by writing a memory file and checking if it auto-commits

## Troubleshooting

- If push fails silently, check `~/dev/claude-memory/.sync.sh status`
- If hook doesn't trigger, verify `~/.claude/settings.json` has the PostToolUse hook
- If memory dir path is wrong, check `sync.memory_dir` in config.yaml
