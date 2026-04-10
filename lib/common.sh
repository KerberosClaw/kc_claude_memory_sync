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

# Load config.sh and export variables
# Searches: $1 (explicit), ./config.sh, script dir, ~/dev/kc_claude_memory_sync/
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
            if [ -f "$dir/config.sh" ]; then
                CONFIG_FILE="$dir/config.sh"
                break
            fi
        done
    fi

    if [ -z "$CONFIG_FILE" ]; then
        error "config.sh not found. Run './setup.sh init' or './setup.sh join' first."
    fi

    # Source the config (shell format)
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Expand ~ in LOCAL_REPO
    LOCAL_REPO="${LOCAL_REPO/#\~/$HOME}"

    # Defaults
    LOCAL_REPO="${LOCAL_REPO:-$HOME/dev/kc_claude_memory}"
}

# Acquire a lock to prevent concurrent git operations
# Usage: acquire_lock || exit 0
acquire_lock() {
    local lock_file="${LOCAL_REPO}/.sync.lock"

    if command -v flock >/dev/null 2>&1; then
        # Linux: fd-based lock, auto-releases on exit
        exec 200>"$lock_file"
        flock -n 200 || return 1
    else
        # macOS / fallback: mkdir-based lock with stale detection
        local lock_dir="${lock_file}.d"
        if ! mkdir "$lock_dir" 2>/dev/null; then
            if [ -d "$lock_dir" ]; then
                # Check if lock is stale (older than 60 seconds)
                local lock_mtime
                lock_mtime=$(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo 0)
                local now
                now=$(date +%s)
                local lock_age=$(( now - lock_mtime ))
                if [ "$lock_age" -gt 60 ]; then
                    rm -rf "$lock_dir"
                    mkdir "$lock_dir" 2>/dev/null || return 1
                else
                    return 1
                fi
            else
                return 1
            fi
        fi
        # Clean up lock on exit
        trap 'rm -rf "'"$lock_dir"'"' EXIT INT TERM
    fi
}
