#!/bin/bash
# Claude Memory Sync — manual sync and status
# Usage:
#   ./sync.sh pull     Pull from GitHub
#   ./sync.sh push     Commit + push to GitHub
#   ./sync.sh sync     Pull then push (default)
#   ./sync.sh status   Show sync status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source common lib
LIB_FILE=""
for candidate in "$SCRIPT_DIR/lib/common.sh" \
                 "$HOME/dev/kc_claude_memory_sync/lib/common.sh"; do
    if [ -f "$candidate" ]; then
        LIB_FILE="$candidate"
        break
    fi
done

if [ -z "$LIB_FILE" ]; then
    echo "ERROR: lib/common.sh not found" >&2
    exit 1
fi

# shellcheck source=lib/common.sh
source "$LIB_FILE"
load_config

ACTION="${1:-sync}"

cd "$LOCAL_REPO"

do_pull() {
    info "Pulling from GitHub..."
    git fetch origin main 2>/dev/null || { warn "Fetch failed -- are you online?"; return 0; }
    git pull --rebase -X theirs origin main 2>/dev/null \
        || git rebase --abort 2>/dev/null \
        || git pull origin main 2>/dev/null \
        || true
    ok "Pull complete"
}

do_push() {
    acquire_lock || { warn "Another sync in progress -- skipping"; return 0; }

    git add -A

    if git diff --cached --quiet 2>/dev/null; then
        # Nothing new to commit, but push any unpushed commits
        _pull_and_push
        return 0
    fi

    git commit -m "memory sync $(date '+%Y-%m-%d %H:%M:%S') from $(hostname)" \
        2>/dev/null || true

    _pull_and_push
}

# Pull then push, with automatic conflict resolution.
# Strategy: try rebase (clean history) -> if conflict, abort and use theirs
_pull_and_push() {
    git fetch origin main 2>/dev/null || return 0

    # Check if we're behind
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        local behind
        behind=$(git rev-list HEAD..origin/main 2>/dev/null | wc -l | tr -d ' ')
        if [ "$behind" -gt 0 ]; then
            info "Pulling $behind commit(s)..."
            if ! git pull --rebase -X theirs origin main 2>/dev/null; then
                git rebase --abort 2>/dev/null || true
                git pull -X ours --no-edit origin main 2>/dev/null || {
                    git merge --abort 2>/dev/null || true
                    warn "Could not auto-resolve conflicts -- push deferred"
                    return 0
                }
            fi
        fi
    fi

    info "Pushing to GitHub..."
    git push origin main 2>/dev/null && ok "Push complete" \
        || warn "Push failed -- will retry next sync"
}

do_status() {
    echo -e "${CYAN}=== Claude Memory Sync Status ===${NC}"
    echo ""

    # Remote URL
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "not configured")
    echo "Remote:        $remote_url"

    # Fetch to get latest state
    git fetch origin main 2>/dev/null || true

    # Last sync time (last commit)
    local last_commit
    last_commit=$(git log -1 --format='%ci' 2>/dev/null || echo "never")
    local last_msg
    last_msg=$(git log -1 --format='%s' 2>/dev/null || echo "")
    echo "Last commit:   $last_commit"
    echo "               $last_msg"

    # Local changes (not yet committed)
    local changed
    changed=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$changed" -gt 0 ]; then
        echo -e "Local changes: ${YELLOW}${changed} file(s) modified (not yet pushed)${NC}"
        git status --porcelain 2>/dev/null | sed 's/^/               /'
    else
        echo -e "Local changes: ${GREEN}none${NC}"
    fi

    # Ahead/behind remote (only if origin/main exists)
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        local ahead behind
        ahead=$(git rev-list origin/main..HEAD 2>/dev/null | wc -l | tr -d ' ')
        behind=$(git rev-list HEAD..origin/main 2>/dev/null | wc -l | tr -d ' ')

        if [ "$ahead" -gt 0 ]; then
            echo -e "Outgoing:      ${YELLOW}${ahead} commit(s) not pushed${NC}"
        fi
        if [ "$behind" -gt 0 ]; then
            echo -e "Incoming:      ${YELLOW}${behind} commit(s) not pulled${NC}"
        fi
        if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
            echo -e "Sync state:    ${GREEN}up to date${NC}"
        fi
    else
        echo -e "Sync state:    ${YELLOW}no remote tracking yet${NC}"
    fi

    # Conflict files
    local conflicts
    conflicts=$(find "$LOCAL_REPO" -maxdepth 1 -name "*_conflict.md" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$conflicts" -gt 0 ]; then
        echo -e "Conflicts:     ${RED}${conflicts} file(s) need review${NC}"
        find "$LOCAL_REPO" -maxdepth 1 -name "*_conflict.md" 2>/dev/null | sed 's/^/               /'
    fi

    echo ""
}

case "$ACTION" in
    pull)   do_pull ;;
    push)   do_push ;;
    sync)   do_pull; do_push ;;
    status) do_status ;;
    *)
        echo "Usage: $0 [pull|push|sync|status]"
        exit 1
        ;;
esac
