#!/bin/bash
# Uninstall Claude Memory Sync — remove settings and hook config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Try to load config for LOCAL_REPO path, but don't fail if missing
CONFIG_FILE=""
for dir in "$SCRIPT_DIR" "$HOME/dev/kc_claude_memory_sync"; do
    if [ -f "$dir/config.sh" ]; then
        CONFIG_FILE="$dir/config.sh"
        break
    fi
done

if [ -n "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    LOCAL_REPO="${LOCAL_REPO/#\~/$HOME}"
fi

echo -e "${YELLOW}=== Claude Memory Sync Uninstall ===${NC}"
echo ""

# Step 1: Remove autoMemoryDirectory from settings.json
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)

# Remove autoMemoryDirectory
settings.pop('autoMemoryDirectory', None)

# Remove memory-sync hook from PostToolUse
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
" && ok "Removed autoMemoryDirectory and hook from settings.json" \
  || warn "Failed to clean settings.json -- remove manually"
else
    warn "settings.json not found -- skipping"
fi

echo ""
ok "Uninstall complete."
if [ -n "${LOCAL_REPO:-}" ]; then
    echo "  Local repo preserved at: $LOCAL_REPO"
    echo "  To fully remove: rm -rf $LOCAL_REPO"
fi
echo ""
