#!/bin/bash
# Claude Memory Sync — setup script
# Usage:
#   ./setup.sh init-hub              # Run on the hub machine (creates bare repo)
#   ./setup.sh join                  # Run on spoke machines (clone + symlink + hook)
#   ./setup.sh init-hub --help       # Show help
#
# Non-interactive mode (for Claude Code automation):
#   ./setup.sh init-hub --hub-host HOST --hub-user USER [options]
#   ./setup.sh join --hub-host HOST --hub-user USER [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_YAML="$SCRIPT_DIR/config.yaml"

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init-hub    Initialize this machine as the hub (bare repo + local setup)"
    echo "  join        Join this machine as a spoke (clone from hub + setup)"
    echo ""
    echo "Options (non-interactive mode):"
    echo "  --hub-host HOST        Hub SSH host/IP"
    echo "  --hub-user USER        Hub SSH username"
    echo "  --bare-repo PATH       Bare repo path on hub (default: ~/git/claude-memory.git)"
    echo "  --ssh-key PATH         SSH key path (default: ~/.ssh/id_ed25519)"
    echo "  --local-repo PATH      Local repo path (default: ~/dev/claude-memory)"
    exit 1
}

# Parse CLI arguments into variables (for non-interactive mode)
parse_args() {
    ARG_HUB_HOST="" ARG_HUB_USER="" ARG_BARE_REPO="" ARG_SSH_KEY="" ARG_LOCAL_REPO=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --hub-host)   ARG_HUB_HOST="$2"; shift 2 ;;
            --hub-user)   ARG_HUB_USER="$2"; shift 2 ;;
            --bare-repo)  ARG_BARE_REPO="$2"; shift 2 ;;
            --ssh-key)    ARG_SSH_KEY="$2"; shift 2 ;;
            --local-repo) ARG_LOCAL_REPO="$2"; shift 2 ;;
            --help|-h)    usage ;;
            *)            shift ;;
        esac
    done
}

# Generate config.yaml — interactive or from CLI args
generate_config() {
    if [ -f "$CONFIG_YAML" ]; then
        info "config.yaml already exists, loading..."
        return
    fi

    local hub_host hub_user bare_repo ssh_key local_repo

    if [ -n "$ARG_HUB_HOST" ] && [ -n "$ARG_HUB_USER" ]; then
        # Non-interactive mode
        hub_host="$ARG_HUB_HOST"
        hub_user="$ARG_HUB_USER"
        bare_repo="${ARG_BARE_REPO:-~/git/claude-memory.git}"
        ssh_key="${ARG_SSH_KEY:-~/.ssh/id_ed25519}"
        local_repo="${ARG_LOCAL_REPO:-~/dev/claude-memory}"
    else
        # Interactive mode
        echo -e "${CYAN}=== Claude Memory Sync Setup ===${NC}"
        echo ""
        read -rp "Hub SSH host (IP or hostname): " hub_host
        read -rp "Hub SSH username: " hub_user
        read -rp "Bare repo path on hub [~/git/claude-memory.git]: " bare_repo
        bare_repo="${bare_repo:-~/git/claude-memory.git}"
        read -rp "SSH key path [~/.ssh/id_ed25519]: " ssh_key
        ssh_key="${ssh_key:-~/.ssh/id_ed25519}"
        read -rp "Local repo directory [~/dev/claude-memory]: " local_repo
        local_repo="${local_repo:-~/dev/claude-memory}"
    fi

    cat > "$CONFIG_YAML" <<CONF
hub:
  host: "$hub_host"
  user: "$hub_user"
  bare_repo: "$bare_repo"

ssh:
  key: "$ssh_key"
  timeout: 3

sync:
  local_repo: "$local_repo"
CONF
    ok "Config saved to $CONFIG_YAML"
    echo ""
}

# Set up symlink: memory dir → local repo
setup_symlink() {
    if [ -L "$LOCAL_MEMORY_DIR" ]; then
        ok "Symlink already exists: $LOCAL_MEMORY_DIR -> $(readlink "$LOCAL_MEMORY_DIR")"
    elif [ -d "$LOCAL_MEMORY_DIR" ]; then
        local backup="${LOCAL_MEMORY_DIR}.bak.$(date +%Y%m%d%H%M%S)"
        info "Backing up original memory dir to $backup"
        mv "$LOCAL_MEMORY_DIR" "$backup"
        ln -s "$LOCAL_REPO" "$LOCAL_MEMORY_DIR"
        ok "Symlink created: $LOCAL_MEMORY_DIR -> $LOCAL_REPO"
    else
        mkdir -p "$(dirname "$LOCAL_MEMORY_DIR")"
        ln -s "$LOCAL_REPO" "$LOCAL_MEMORY_DIR"
        ok "Symlink created: $LOCAL_MEMORY_DIR -> $LOCAL_REPO"
    fi
}

# Install Claude Code PostToolUse hook
install_hook() {
    info "Installing Claude Code hook..."
    local hooks_dir="$HOME/.claude/hooks"
    local hook_script="$hooks_dir/memory-sync.sh"
    local settings_file="$HOME/.claude/settings.json"

    mkdir -p "$hooks_dir"
    cp "$SCRIPT_DIR/hooks/memory-sync.sh" "$hook_script"
    chmod +x "$hook_script"

    # Copy sync runtime files into the memory repo so the hook can find them
    # These dot-files live alongside the memory .md files
    cp "$SCRIPT_DIR/sync.sh" "$LOCAL_REPO/.sync.sh"
    chmod +x "$LOCAL_REPO/.sync.sh"
    cp "$SCRIPT_DIR/lib/common.sh" "$LOCAL_REPO/.common.sh"
    cp "$CONFIG_YAML" "$LOCAL_REPO/.config.yaml"

    if [ -f "$settings_file" ]; then
        if grep -q "memory-sync" "$settings_file" 2>/dev/null; then
            ok "Hook already configured in settings.json"
        elif grep -q '"PostToolUse"' "$settings_file" 2>/dev/null; then
            # PostToolUse exists — append our hook to it
            python3 -c "
import json
with open('$settings_file') as f:
    settings = json.load(f)
hook_entry = {
    'matcher': 'Write|Edit',
    'hooks': [{
        'type': 'command',
        'command': '$hook_script',
        'timeout': 15,
        'async': True
    }]
}
settings.setdefault('hooks', {}).setdefault('PostToolUse', []).append(hook_entry)
with open('$settings_file', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" && ok "Hook appended to existing PostToolUse in settings.json" \
  || warn "Failed to update settings.json — add hook manually (see README)"
        else
            python3 -c "
import json
with open('$settings_file') as f:
    settings = json.load(f)
settings['hooks'] = {
    'PostToolUse': [{
        'matcher': 'Write|Edit',
        'hooks': [{
            'type': 'command',
            'command': '$hook_script',
            'timeout': 15,
            'async': True
        }]
    }]
}
with open('$settings_file', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" && ok "Hook added to settings.json" \
  || warn "Failed to update settings.json — add hook manually (see README)"
        fi
    else
        warn "$settings_file not found — skipping hook install"
    fi
}

# ============================================================
# init-hub: run on the machine that will host the bare repo
# ============================================================
cmd_init_hub() {
    parse_args "$@"
    generate_config
    load_config "$CONFIG_YAML"

    # Step 1: Create bare repo (locally — this IS the hub)
    # HUB_BARE_REPO is already ~ expanded by load_config
    local bare_path="$HUB_BARE_REPO"
    info "Creating bare repo at $bare_path..."
    if [ -d "$bare_path" ]; then
        ok "Bare repo already exists"
    else
        mkdir -p "$(dirname "$bare_path")"
        git init --bare "$bare_path"
        ok "Bare repo created"
    fi

    # Step 2: Clone bare repo locally
    info "Setting up local repo at $LOCAL_REPO..."
    if [ -d "$LOCAL_REPO/.git" ]; then
        ok "Local repo already exists"
    else
        mkdir -p "$LOCAL_REPO"
        cd "$LOCAL_REPO"
        git init
        git remote add origin "$bare_path"
        ok "Local repo initialized"
    fi

    # Ensure memory repo ignores sync runtime files
    if [ ! -f "$LOCAL_REPO/.gitignore" ]; then
        cat > "$LOCAL_REPO/.gitignore" <<'GITIGNORE'
.sync.sh
.sync.lock
.sync.lock.d
.common.sh
.config.yaml
.DS_Store
GITIGNORE
    fi

    # Step 3: Copy existing memory files into repo and rebuild index
    if [ -d "$LOCAL_MEMORY_DIR" ] && [ ! -L "$LOCAL_MEMORY_DIR" ]; then
        info "Copying existing memory files..."
        cp -n "$LOCAL_MEMORY_DIR"/*.md "$LOCAL_REPO/" 2>/dev/null || true
        "$SCRIPT_DIR/lib/merge-memory.sh" "$LOCAL_MEMORY_DIR" "$LOCAL_REPO"
    else
        info "No existing memory directory found — starting fresh"
    fi

    # Step 5: Initial commit + push
    cd "$LOCAL_REPO"
    git add -A
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "Initial memory from $(hostname)"
        git branch -M main
        git push -u origin main
        ok "Initial commit pushed"
    else
        ok "No new files to commit"
    fi

    # Step 6: Symlink
    setup_symlink

    # Step 7: Hook
    install_hook

    echo ""
    echo -e "${GREEN}=== Hub Setup Complete ===${NC}"
    echo ""
    echo "Bare repo:  $bare_path"
    echo "Local repo: $LOCAL_REPO"
    echo "Memory dir: $LOCAL_MEMORY_DIR -> $LOCAL_REPO"
    echo ""
    echo "Next: run './setup.sh join' on your other machines."
    echo ""
}

# ============================================================
# join: run on spoke machines to connect to the hub
# ============================================================
cmd_join() {
    parse_args "$@"
    generate_config
    load_config "$CONFIG_YAML"

    # Step 1: Verify SSH connection to hub
    info "Testing SSH connection to $REMOTE..."
    if hub_reachable; then
        ok "SSH connection successful"
    else
        error "Cannot connect to $REMOTE. Set up passwordless SSH first:
  ssh-copy-id -i ${SSH_KEY}.pub $REMOTE"
    fi

    # Step 2: Verify bare repo exists on hub
    info "Checking bare repo on hub..."
    if $SSH_CMD "$REMOTE" "[ -d $HUB_BARE_REPO_RAW ]" 2>/dev/null; then
        ok "Bare repo found on hub"
    else
        error "Bare repo not found at $REMOTE:$HUB_BARE_REPO_RAW
  Run './setup.sh init-hub' on the hub machine first."
    fi

    # Step 3: Clone from hub
    info "Setting up local repo at $LOCAL_REPO..."
    if [ -d "$LOCAL_REPO/.git" ]; then
        ok "Local repo already exists"
        cd "$LOCAL_REPO"
        git pull origin main 2>/dev/null || true
    else
        git clone "$REMOTE:$HUB_BARE_REPO_RAW" "$LOCAL_REPO"
        cd "$LOCAL_REPO"
        ok "Cloned from hub"
    fi

    # Step 4: Merge local memory files into repo
    if [ -d "$LOCAL_MEMORY_DIR" ] && [ ! -L "$LOCAL_MEMORY_DIR" ]; then
        info "Merging local memory files..."
        "$SCRIPT_DIR/lib/merge-memory.sh" "$LOCAL_MEMORY_DIR" "$LOCAL_REPO"

        # Commit and push merged files
        cd "$LOCAL_REPO"
        git add -A
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "Merge memory from $(hostname)"
            git push origin main
            ok "Merged memory pushed to hub"
        fi
    fi

    # Step 5: Symlink
    setup_symlink

    # Step 6: Hook
    install_hook

    echo ""
    echo -e "${GREEN}=== Join Complete ===${NC}"
    echo ""
    echo "Hub:        $REMOTE:$HUB_BARE_REPO_RAW"
    echo "Local repo: $LOCAL_REPO"
    echo "Memory dir: $LOCAL_MEMORY_DIR -> $LOCAL_REPO"
    echo ""
    echo "Memory will auto-sync when Claude Code writes/edits memory files."
    if [ -n "$(ls "$LOCAL_REPO"/*_conflict.md 2>/dev/null)" ]; then
        echo ""
        warn "Conflict files found — review and merge:"
        ls "$LOCAL_REPO"/*_conflict.md 2>/dev/null
    fi
    echo ""
}

# ============================================================
# Main
# ============================================================
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    init-hub) cmd_init_hub "$@" ;;
    join)     cmd_join "$@" ;;
    *)        usage ;;
esac
