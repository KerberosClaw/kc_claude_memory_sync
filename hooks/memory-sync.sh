#!/bin/bash
# Claude Code PostToolUse hook — auto push memory to GitHub
#
# Triggered on Write/Edit. Only acts if the file is inside the memory repo.
# Must ALWAYS exit 0 to avoid blocking Claude Code.

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -z "$FILE_PATH" ] && exit 0

REAL_PATH=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# Read memory repo path from Claude Code settings
MEMORY_REPO=""
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    MEMORY_REPO=$(jq -r '.autoMemoryDirectory // empty' "$SETTINGS" 2>/dev/null || true)
    MEMORY_REPO="${MEMORY_REPO/#\~/$HOME}"
fi
[ -z "$MEMORY_REPO" ] && exit 0
[ -d "$MEMORY_REPO/.git" ] || exit 0

case "$REAL_PATH" in
    "$MEMORY_REPO"*)
        cd "$MEMORY_REPO" || exit 0
        # Lock to prevent concurrent pushes
        LOCK="$MEMORY_REPO/.git/sync.lock"
        if ! mkdir "$LOCK" 2>/dev/null; then
            exit 0
        fi
        trap 'rmdir "$LOCK" 2>/dev/null' EXIT

        git add -A >/dev/null 2>&1
        git diff --cached --quiet && exit 0
        git commit -m "sync: update memory" >/dev/null 2>&1

        # pull before push, last write wins on conflict
        git pull --rebase -X theirs --quiet >/dev/null 2>&1 \
            || git rebase --abort >/dev/null 2>&1
        git push >/dev/null 2>&1 &
        ;;
esac

exit 0
