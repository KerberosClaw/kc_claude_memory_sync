#!/bin/bash
# Shared functions for claude-memory-sync scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Parse YAML config using python3 (no external deps)
# Usage: parse_yaml config.yaml "hub.host"
parse_yaml() {
    local file="$1"
    local key="$2"
    python3 -c "
import yaml, sys
with open('$file') as f:
    d = yaml.safe_load(f)
keys = '$key'.split('.')
for k in keys:
    if d is None:
        break
    d = d.get(k)
print(d if d is not None else '')
" 2>/dev/null
}

# Load config.yaml and export variables
# Searches: $1 (explicit), ./config.yaml, script dir, ~/dev/kc_claude_memory_sync/
load_config() {
    local config_file="${1:-}"
    local search_dirs=(
        "."
        "$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        "$HOME/dev/kc_claude_memory_sync"
    )

    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        CONFIG_FILE="$config_file"
    else
        CONFIG_FILE=""
        for dir in "${search_dirs[@]}"; do
            if [ -f "$dir/config.yaml" ]; then
                CONFIG_FILE="$dir/config.yaml"
                break
            fi
        done
    fi

    if [ -z "$CONFIG_FILE" ]; then
        error "config.yaml not found. Run './setup.sh init-hub' or './setup.sh join' first."
    fi

    HUB_HOST=$(parse_yaml "$CONFIG_FILE" "hub.host")
    HUB_USER=$(parse_yaml "$CONFIG_FILE" "hub.user")
    HUB_BARE_REPO=$(parse_yaml "$CONFIG_FILE" "hub.bare_repo")
    SSH_KEY=$(parse_yaml "$CONFIG_FILE" "ssh.key")
    SSH_TIMEOUT=$(parse_yaml "$CONFIG_FILE" "ssh.timeout")
    LOCAL_REPO=$(parse_yaml "$CONFIG_FILE" "sync.local_repo")
    LOCAL_MEMORY_DIR=$(parse_yaml "$CONFIG_FILE" "sync.memory_dir")

    # Expand ~ in paths
    SSH_KEY=$(eval echo "$SSH_KEY")
    LOCAL_REPO=$(eval echo "$LOCAL_REPO")
    HUB_BARE_REPO=$(eval echo "$HUB_BARE_REPO")

    # Defaults
    SSH_TIMEOUT="${SSH_TIMEOUT:-3}"
    LOCAL_REPO="${LOCAL_REPO:-$HOME/dev/claude-memory}"
    LOCAL_MEMORY_DIR="${LOCAL_MEMORY_DIR:-$HOME/.claude/projects/-Users-$(whoami)/memory}"

    SSH_CMD="ssh -i $SSH_KEY -o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes"
    REMOTE="$HUB_USER@$HUB_HOST"
}

# Check if hub is reachable via SSH
hub_reachable() {
    $SSH_CMD "$REMOTE" "true" 2>/dev/null
}

# Acquire a lock to prevent concurrent git operations
# Usage: acquire_lock || exit 0
acquire_lock() {
    local lock_file="${LOCAL_REPO}/.sync.lock"
    if command -v flock >/dev/null 2>&1; then
        exec 200>"$lock_file"
        flock -n 200 || return 1
    elif command -v shlock >/dev/null 2>&1; then
        shlock -f "$lock_file" -p $$ || return 1
    else
        # Fallback: simple mkdir-based lock
        if ! mkdir "$lock_file.d" 2>/dev/null; then
            # Check if lock is stale (older than 60 seconds)
            if [ -d "$lock_file.d" ]; then
                local lock_age=$(( $(date +%s) - $(stat -f %m "$lock_file.d" 2>/dev/null || stat -c %Y "$lock_file.d" 2>/dev/null || echo 0) ))
                if [ "$lock_age" -gt 60 ]; then
                    rm -rf "$lock_file.d"
                    mkdir "$lock_file.d" 2>/dev/null || return 1
                else
                    return 1
                fi
            fi
        fi
        trap "rm -rf '$lock_file.d'" EXIT
    fi
}
