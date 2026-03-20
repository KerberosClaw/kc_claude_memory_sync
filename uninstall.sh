#!/bin/bash
# Uninstall Claude Memory Sync — restore original memory directory and remove hooks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_config "$SCRIPT_DIR/config.yaml"

echo -e "${YELLOW}=== Claude Memory Sync Uninstall ===${NC}"
echo ""

# Step 1: Restore memory directory from symlink
if [ -L "$LOCAL_MEMORY_DIR" ]; then
    info "Removing symlink: $LOCAL_MEMORY_DIR"
    rm "$LOCAL_MEMORY_DIR"

    BACKUP=$(ls -d "${LOCAL_MEMORY_DIR}.bak."* 2>/dev/null | sort -r | head -1 || true)
    if [ -n "$BACKUP" ]; then
        info "Restoring from backup: $BACKUP"
        mv "$BACKUP" "$LOCAL_MEMORY_DIR"
        ok "Original memory directory restored"
    else
        info "No backup found — copying current files from repo"
        mkdir -p "$LOCAL_MEMORY_DIR"
        cp "$LOCAL_REPO"/*.md "$LOCAL_MEMORY_DIR/" 2>/dev/null || true
        ok "Memory files copied to $LOCAL_MEMORY_DIR"
    fi
else
    warn "No symlink found at $LOCAL_MEMORY_DIR — skipping"
fi

# Step 2: Remove hook script
HOOK_SCRIPT="$HOME/.claude/hooks/memory-sync.sh"
if [ -f "$HOOK_SCRIPT" ]; then
    rm "$HOOK_SCRIPT"
    ok "Hook script removed"
fi

# Step 3: Remove hook from settings.json
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ] && grep -q "memory-sync" "$SETTINGS_FILE" 2>/dev/null; then
    python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)
if 'hooks' in settings and 'PostToolUse' in settings['hooks']:
    settings['hooks']['PostToolUse'] = [
        h for h in settings['hooks']['PostToolUse']
        if not any('memory-sync' in hook.get('command', '') for hook in h.get('hooks', []))
    ]
    if not settings['hooks']['PostToolUse']:
        del settings['hooks']['PostToolUse']
    if not settings['hooks']:
        del settings['hooks']
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" && ok "Hook config removed from settings.json" \
  || warn "Failed to clean settings.json — remove hook manually"
fi

echo ""
ok "Uninstall complete."
echo "  Local repo preserved at: $LOCAL_REPO"
echo "  To fully remove: rm -rf $LOCAL_REPO"
echo ""
