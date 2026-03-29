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

# Parse simple YAML config using pure python3 (no PyYAML dependency)
# Supports only flat nested keys like hub.host, ssh.timeout, etc.
# Usage: parse_yaml config.yaml "hub.host"
parse_yaml() {
    local file="$1"
    local key="$2"
    python3 -c "
import re, sys

def parse_simple_yaml(filepath):
    result = {}
    current_section = None
    with open(filepath) as f:
        for line in f:
            line = line.rstrip()
            if not line or line.lstrip().startswith('#'):
                continue
            # Top-level key (no leading whitespace)
            m = re.match(r'^(\w+):\s*$', line)
            if m:
                current_section = m.group(1)
                continue
            # Nested key-value
            m = re.match(r'^\s+(\w+):\s+(.+)$', line)
            if m and current_section:
                val = m.group(2).strip()
                # Remove surrounding quotes
                if (val.startswith('\"') and val.endswith('\"')) or \
                   (val.startswith(\"'\") and val.endswith(\"'\")):
                    val = val[1:-1]
                # Remove inline comments
                val = re.sub(r'\s+#.*$', '', val)
                result[current_section + '.' + m.group(1)] = val
    return result

data = parse_simple_yaml('$file')
print(data.get('$key', ''))
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
            # Check config.yaml (project dir) and .config.yaml (memory repo)
            if [ -f "$dir/config.yaml" ]; then
                CONFIG_FILE="$dir/config.yaml"
                break
            elif [ -f "$dir/.config.yaml" ]; then
                CONFIG_FILE="$dir/.config.yaml"
                break
            fi
        done
    fi

    if [ -z "$CONFIG_FILE" ]; then
        error "config.yaml not found. Run './setup.sh init-hub' or './setup.sh join' first."
    fi

    HUB_HOST=$(parse_yaml "$CONFIG_FILE" "hub.host")
    HUB_FALLBACK_HOST=$(parse_yaml "$CONFIG_FILE" "hub.fallback_host")
    HUB_USER=$(parse_yaml "$CONFIG_FILE" "hub.user")
    HUB_BARE_REPO=$(parse_yaml "$CONFIG_FILE" "hub.bare_repo")
    SSH_KEY=$(parse_yaml "$CONFIG_FILE" "ssh.key")
    SSH_TIMEOUT=$(parse_yaml "$CONFIG_FILE" "ssh.timeout")
    LOCAL_REPO=$(parse_yaml "$CONFIG_FILE" "sync.local_repo")
    LOCAL_MEMORY_DIR=$(parse_yaml "$CONFIG_FILE" "sync.memory_dir")

    # Keep raw bare_repo path for SSH remote operations (~ expands on remote)
    HUB_BARE_REPO_RAW="$HUB_BARE_REPO"

    # Expand ~ in local paths only
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    LOCAL_REPO="${LOCAL_REPO/#\~/$HOME}"
    # HUB_BARE_REPO: expand ~ for local use (init-hub), keep RAW for remote (join)
    HUB_BARE_REPO="${HUB_BARE_REPO/#\~/$HOME}"

    # Defaults
    SSH_TIMEOUT="${SSH_TIMEOUT:-3}"
    LOCAL_REPO="${LOCAL_REPO:-$HOME/dev/claude-memory}"
    LOCAL_MEMORY_DIR="${LOCAL_MEMORY_DIR:-$HOME/.claude/projects/-Users-$(whoami)/memory}"

    SSH_CMD="ssh -i $SSH_KEY -o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes"
    REMOTE="$HUB_USER@$HUB_HOST"
}

# Check if hub is reachable
# If git remote is a local path (hub machine), always reachable.
# If git remote is SSH, try primary host first, then fallback_host (LAN IP).
# When fallback succeeds, temporarily switches git remote for this sync only,
# then restores the original remote URL afterward.
hub_reachable() {
    local remote_url
    remote_url=$(git -C "$LOCAL_REPO" remote get-url origin 2>/dev/null || true)
    # Local path (starts with / or ~) → always reachable
    if [[ "$remote_url" == /* ]] || [[ "$remote_url" == ~* ]]; then
        return 0
    fi
    # SSH remote → try primary host
    if $SSH_CMD "$REMOTE" "true" 2>/dev/null; then
        # Ensure remote URL points to primary (restore if previously changed)
        local primary_url="${REMOTE}:${HUB_BARE_REPO_RAW}"
        if [[ "$remote_url" != "$primary_url" ]]; then
            git -C "$LOCAL_REPO" remote set-url origin "$primary_url" 2>/dev/null
        fi
        return 0
    fi
    # Primary failed → try fallback host (LAN IP)
    if [ -n "$HUB_FALLBACK_HOST" ]; then
        local fallback_remote="$HUB_USER@$HUB_FALLBACK_HOST"
        if $SSH_CMD "$fallback_remote" "true" 2>/dev/null; then
            # Temporarily switch to fallback
            REMOTE="$fallback_remote"
            _ORIGINAL_REMOTE_URL="$remote_url"
            git -C "$LOCAL_REPO" remote set-url origin "${fallback_remote}:${HUB_BARE_REPO_RAW}" 2>/dev/null
            # Restore original remote URL on exit
            trap '_restore_remote' EXIT
            return 0
        fi
    fi
    return 1
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
        trap 'rm -rf "'"$lock_dir"'"; _restore_remote' EXIT INT TERM
    fi
}

# Restore git remote URL to primary host after fallback
_restore_remote() {
    if [ -n "${_ORIGINAL_REMOTE_URL:-}" ]; then
        git -C "$LOCAL_REPO" remote set-url origin "$_ORIGINAL_REMOTE_URL" 2>/dev/null || true
    fi
}
