#!/bin/bash
# Claude Memory Sync — setup script
# Usage:
#   ./setup.sh init              # First machine: create GitHub repo + git-crypt + push
#   ./setup.sh join              # Additional machines: clone + unlock + merge
#
# Non-interactive mode:
#   ./setup.sh init --repo-name kc_claude_memory --local-repo ~/dev/kc_claude_memory
#   ./setup.sh join --repo-url https://github.com/user/repo.git --key-file /tmp/key --local-repo ~/dev/kc_claude_memory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init    First machine: create GitHub private repo, git-crypt, push"
    echo "  join    Additional machines: clone, unlock, merge local memory"
    echo ""
    echo "Options for init:"
    echo "  --repo-name NAME      GitHub repo name (default: kc_claude_memory)"
    echo "  --local-repo PATH     Local clone path (default: ~/dev/kc_claude_memory)"
    echo ""
    echo "Options for join:"
    echo "  --repo-url URL        GitHub repo URL (HTTPS or SSH)"
    echo "  --key-file PATH       Path to git-crypt key file"
    echo "  --local-repo PATH     Local clone path (default: ~/dev/kc_claude_memory)"
    exit 1
}

# Parse CLI arguments
parse_args() {
    ARG_REPO_NAME="" ARG_REPO_URL="" ARG_KEY_FILE="" ARG_LOCAL_REPO=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo-name)  ARG_REPO_NAME="$2"; shift 2 ;;
            --repo-url)   ARG_REPO_URL="$2"; shift 2 ;;
            --key-file)   ARG_KEY_FILE="$2"; shift 2 ;;
            --local-repo) ARG_LOCAL_REPO="$2"; shift 2 ;;
            --help|-h)    usage ;;
            *)            shift ;;
        esac
    done
}

# Check that required tools are installed
check_prereqs() {
    local missing=()
    command -v git >/dev/null 2>&1        || missing+=("git")
    command -v jq >/dev/null 2>&1         || missing+=("jq")
    command -v gh >/dev/null 2>&1         || missing+=("gh (GitHub CLI)")
    command -v python3 >/dev/null 2>&1    || missing+=("python3")

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing prerequisites: ${missing[*]}
  Install them and try again."
    fi

    # Check gh auth
    if ! gh auth status >/dev/null 2>&1; then
        error "GitHub CLI not authenticated. Run: gh auth login"
    fi
}

check_git_crypt() {
    if ! command -v git-crypt >/dev/null 2>&1; then
        error "git-crypt not installed.
  macOS: brew install git-crypt
  Linux: sudo apt install git-crypt"
    fi
}

# Configure autoMemoryDirectory and PostToolUse hook in settings.json
configure_settings() {
    local local_repo="$1"
    local settings_file="$HOME/.claude/settings.json"
    local hook_command="$SCRIPT_DIR/hooks/memory-sync.sh"

    mkdir -p "$HOME/.claude"

    # Create settings.json if it doesn't exist
    if [ ! -f "$settings_file" ]; then
        echo '{}' > "$settings_file"
    fi

    info "Configuring Claude Code settings..."

    python3 -c "
import json, sys

settings_path = '$settings_file'
with open(settings_path) as f:
    settings = json.load(f)

# Set autoMemoryDirectory
settings['autoMemoryDirectory'] = '$local_repo'

# Set up PostToolUse hook
hook_entry = {
    'matcher': 'Write|Edit',
    'hooks': [{
        'type': 'command',
        'command': '$hook_command',
        'timeout': 15
    }]
}

post_hooks = settings.setdefault('hooks', {}).setdefault('PostToolUse', [])

# Remove existing memory-sync hooks, then add ours
post_hooks[:] = [
    h for h in post_hooks
    if not any('memory-sync' in hook.get('command', '') for hook in h.get('hooks', []))
]
post_hooks.append(hook_entry)

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" && ok "autoMemoryDirectory and hook configured in settings.json" \
  || warn "Failed to update settings.json -- configure manually (see README)"
}

# Migrate existing memory files from Claude Code default location
migrate_existing_memory() {
    local target_repo="$1"
    local default_memory_dir="$HOME/.claude/projects/-Users-$(whoami)/memory"

    if [ -d "$default_memory_dir" ] && [ ! -L "$default_memory_dir" ]; then
        info "Found existing memory files in $default_memory_dir"
        "$SCRIPT_DIR/lib/merge-memory.sh" "$default_memory_dir" "$target_repo"
    else
        info "No existing memory directory found -- starting fresh"
    fi
}

# ============================================================
# init: first machine — create GitHub repo + git-crypt + push
# ============================================================
cmd_init() {
    parse_args "$@"
    check_prereqs
    check_git_crypt

    local repo_name local_repo

    if [ -n "$ARG_REPO_NAME" ]; then
        repo_name="$ARG_REPO_NAME"
        local_repo="${ARG_LOCAL_REPO:-~/dev/$repo_name}"
    else
        echo -e "${CYAN}=== Claude Memory Sync — Init ===${NC}"
        echo ""
        read -rp "GitHub repo name [kc_claude_memory]: " repo_name
        repo_name="${repo_name:-kc_claude_memory}"
        read -rp "Local clone path [~/dev/$repo_name]: " local_repo
        local_repo="${local_repo:-~/dev/$repo_name}"
    fi

    # Expand ~
    local_repo="${local_repo/#\~/$HOME}"

    # Step 1: Create GitHub private repo
    info "Creating GitHub private repo: $repo_name..."
    local repo_url
    repo_url=$(gh repo create "$repo_name" --private --clone=false 2>&1) || {
        # If repo already exists, get the URL
        if echo "$repo_url" | grep -qi "already exists"; then
            warn "Repo already exists on GitHub"
            repo_url=$(gh repo view "$repo_name" --json url -q .url 2>/dev/null || true)
        else
            error "Failed to create repo: $repo_url"
        fi
    }

    # Get the actual repo URL
    if [ -z "$repo_url" ] || ! echo "$repo_url" | grep -q "github.com"; then
        repo_url=$(gh repo view "$repo_name" --json url -q .url 2>/dev/null || true)
    fi

    if [ -z "$repo_url" ]; then
        error "Could not determine repo URL. Check 'gh repo list' and try again."
    fi
    ok "GitHub repo: $repo_url"

    # Step 2: Init local repo
    info "Setting up local repo at $local_repo..."
    if [ -d "$local_repo/.git" ]; then
        ok "Local repo already exists"
    else
        mkdir -p "$local_repo"
        git init "$local_repo"
    fi

    cd "$local_repo"

    # Set remote
    if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url origin "$repo_url"
    else
        git remote add origin "$repo_url"
    fi

    # Step 3: git-crypt init + export key
    local key_file="$local_repo/.git/git-crypt-key"
    if [ -f "$key_file" ]; then
        ok "git-crypt already initialized"
    else
        info "Initializing git-crypt..."
        git-crypt init
        git-crypt export-key "$key_file"
        ok "git-crypt initialized, key exported to $key_file"
    fi

    # Step 4: .gitattributes for encryption
    if [ ! -f "$local_repo/.gitattributes" ]; then
        cat > "$local_repo/.gitattributes" <<'ATTR'
*.md filter=git-crypt diff=git-crypt
.gitattributes !filter !diff
ATTR
        ok "Created .gitattributes (encrypts *.md files)"
    fi

    # .gitignore for the memory repo
    if [ ! -f "$local_repo/.gitignore" ]; then
        cat > "$local_repo/.gitignore" <<'GITIGNORE'
.DS_Store
.sync.lock
.sync.lock.d
GITIGNORE
    fi

    # Step 5: Migrate existing memory files
    migrate_existing_memory "$local_repo"

    # Step 6: Initial commit + push
    cd "$local_repo"
    git add -A
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "Initial memory from $(hostname)"
        git branch -M main
        git push -u origin main
        ok "Initial commit pushed"
    else
        if git log --oneline -1 >/dev/null 2>&1; then
            ok "No new files to commit"
        else
            # Empty repo, need at least one commit
            git commit --allow-empty -m "Initial commit"
            git branch -M main
            git push -u origin main
            ok "Empty initial commit pushed"
        fi
    fi

    # Step 7: Save config
    local config_file="$SCRIPT_DIR/config.sh"
    cat > "$config_file" <<CONF
# Claude Memory Sync Configuration
REPO_URL="$repo_url"
LOCAL_REPO="$local_repo"
CONF
    ok "Config saved to $config_file"

    # Step 8: Configure Claude Code settings
    configure_settings "$local_repo"

    echo ""
    echo -e "${GREEN}=== Init Complete ===${NC}"
    echo ""
    echo "Repo:       $repo_url"
    echo "Local:      $local_repo"
    echo "Key file:   $key_file"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Back up the key file!${NC}"
    echo "Without this key, you cannot decrypt memory on other machines."
    echo "Copy it to a safe location (USB drive, password manager, etc.):"
    echo ""
    echo "  scp $key_file other-machine:/tmp/git-crypt-key"
    echo ""
    echo "Next: run './setup.sh join' on your other machines."
    echo ""
}

# ============================================================
# join: additional machines — clone + unlock + merge
# ============================================================
cmd_join() {
    parse_args "$@"
    check_prereqs
    check_git_crypt

    local repo_url key_file local_repo

    if [ -n "$ARG_REPO_URL" ] && [ -n "$ARG_KEY_FILE" ]; then
        repo_url="$ARG_REPO_URL"
        key_file="$ARG_KEY_FILE"
        local_repo="${ARG_LOCAL_REPO:-~/dev/kc_claude_memory}"
    else
        echo -e "${CYAN}=== Claude Memory Sync — Join ===${NC}"
        echo ""
        read -rp "GitHub repo URL: " repo_url
        read -rp "Path to git-crypt key file: " key_file
        read -rp "Local clone path [~/dev/kc_claude_memory]: " local_repo
        local_repo="${local_repo:-~/dev/kc_claude_memory}"
    fi

    # Expand ~
    local_repo="${local_repo/#\~/$HOME}"
    key_file="${key_file/#\~/$HOME}"

    if [ ! -f "$key_file" ]; then
        error "Key file not found: $key_file"
    fi

    # Step 1: Clone repo
    info "Cloning repo to $local_repo..."
    if [ -d "$local_repo/.git" ]; then
        ok "Local repo already exists"
        cd "$local_repo"
        git pull origin main 2>/dev/null || true
    else
        git clone "$repo_url" "$local_repo"
        cd "$local_repo"
        ok "Cloned from GitHub"
    fi

    # Step 2: Unlock with git-crypt
    info "Unlocking encrypted files..."
    if git-crypt unlock "$key_file" 2>/dev/null; then
        ok "Repository unlocked"
    else
        # May already be unlocked
        if git-crypt status >/dev/null 2>&1; then
            ok "Repository already unlocked"
        else
            error "Failed to unlock repository. Is the key file correct?"
        fi
    fi

    # Step 3: Merge local memory files
    migrate_existing_memory "$local_repo"

    # Commit and push merged files
    cd "$local_repo"
    git add -A
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "Merge memory from $(hostname)"
        git pull --rebase -X theirs origin main 2>/dev/null \
            || git rebase --abort 2>/dev/null || true
        git push origin main
        ok "Merged memory pushed"
    fi

    # Step 4: Save config
    local config_file="$SCRIPT_DIR/config.sh"
    cat > "$config_file" <<CONF
# Claude Memory Sync Configuration
REPO_URL="$repo_url"
LOCAL_REPO="$local_repo"
CONF
    ok "Config saved to $config_file"

    # Step 5: Configure Claude Code settings
    configure_settings "$local_repo"

    echo ""
    echo -e "${GREEN}=== Join Complete ===${NC}"
    echo ""
    echo "Repo:       $repo_url"
    echo "Local:      $local_repo"
    echo ""
    echo "Memory will auto-sync when Claude Code writes/edits memory files."
    if ls "$local_repo"/*_conflict.md >/dev/null 2>&1; then
        echo ""
        warn "Conflict files found -- review and merge:"
        ls "$local_repo"/*_conflict.md 2>/dev/null
    fi
    echo ""
    echo -e "${YELLOW}TIP: Delete the key file from its transfer location for security:${NC}"
    echo "  rm $key_file"
    echo ""
}

# ============================================================
# Main
# ============================================================
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    init) cmd_init "$@" ;;
    join) cmd_join "$@" ;;
    *)    usage ;;
esac
