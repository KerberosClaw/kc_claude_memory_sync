#!/bin/bash
# Claude Code PostToolUse hook — auto-sync memory after Write/Edit
#
# Triggered when Claude writes or edits a file.
# Only syncs if the file is inside the memory directory.
# This script must ALWAYS exit 0 to avoid blocking Claude Code.

# Do NOT use set -e here — hook must never fail

# Ensure jq is available
command -v jq >/dev/null 2>&1 || exit 0

# Read hook input from stdin
INPUT=$(cat)

# Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Resolve symlinks to get the real path
REAL_PATH=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# Find the memory repo directory (resolve the symlink)
MEMORY_LINK="$HOME/.claude/projects/-Users-$(whoami)/memory"
if [ -L "$MEMORY_LINK" ]; then
    MEMORY_REPO=$(realpath "$MEMORY_LINK" 2>/dev/null || readlink "$MEMORY_LINK")
else
    exit 0
fi

# Check if the written file is inside the memory repo
case "$REAL_PATH" in
    "$MEMORY_REPO"*)
        # File is in memory repo — trigger sync in background
        SYNC_SCRIPT="$MEMORY_REPO/.sync.sh"
        if [ -x "$SYNC_SCRIPT" ]; then
            "$SYNC_SCRIPT" push >/dev/null 2>&1 &
        fi
        ;;
esac

exit 0
