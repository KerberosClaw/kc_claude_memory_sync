#!/bin/bash
# Merge memory files from a source directory into the target repo.
# - Files only in source → copy to target
# - Files only in target → keep
# - Same filename, same content → skip
# - Same filename, different content → keep both (add _conflict suffix)
# - MEMORY.md → auto-merge index entries, deduplicate
#
# Usage: ./merge-memory.sh <source_dir> <target_dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SOURCE_DIR="${1:?Usage: merge-memory.sh <source_dir> <target_dir>}"
TARGET_DIR="${2:?Usage: merge-memory.sh <source_dir> <target_dir>}"

if [ ! -d "$SOURCE_DIR" ]; then
    error "Source directory not found: $SOURCE_DIR"
fi

mkdir -p "$TARGET_DIR"

MERGED=0
SKIPPED=0
CONFLICTS=0

for src_file in "$SOURCE_DIR"/*.md; do
    [ -f "$src_file" ] || continue
    fname=$(basename "$src_file")

    # Handle MEMORY.md separately
    if [ "$fname" = "MEMORY.md" ]; then
        continue
    fi

    target_file="$TARGET_DIR/$fname"

    if [ ! -f "$target_file" ]; then
        # Only in source → copy
        cp "$src_file" "$target_file"
        info "Added: $fname"
        MERGED=$((MERGED + 1))
    elif diff -q "$src_file" "$target_file" >/dev/null 2>&1; then
        # Same content → skip
        SKIPPED=$((SKIPPED + 1))
    else
        # Different content → save with suffix for review
        conflict_name="${fname%.md}_conflict.md"
        cp "$src_file" "$TARGET_DIR/$conflict_name"
        warn "Conflict: $fname — saved remote version as $conflict_name"
        CONFLICTS=$((CONFLICTS + 1))
    fi
done

# Merge MEMORY.md index
merge_memory_index() {
    local src_index="$SOURCE_DIR/MEMORY.md"
    local tgt_index="$TARGET_DIR/MEMORY.md"

    # Collect all index entries from both files
    # Format: "- [filename.md](filename.md) — description"
    local tmp_merged
    tmp_merged=$(mktemp)

    # Extract entries (lines starting with "- [")
    { grep '^\- \[' "$src_index" 2>/dev/null || true
      grep '^\- \[' "$tgt_index" 2>/dev/null || true
    } | sort -u > "$tmp_merged"

    # Also scan for .md files not listed in any index
    for f in "$TARGET_DIR"/*.md; do
        [ -f "$f" ] || continue
        local base
        base=$(basename "$f")
        [ "$base" = "MEMORY.md" ] && continue
        [[ "$base" == *_conflict.md ]] && continue

        if ! grep -q "\[$base\]" "$tmp_merged" 2>/dev/null; then
            # Extract description from frontmatter
            local desc=""
            desc=$(grep '^description:' "$f" 2>/dev/null | head -1 | sed 's/^description: *//' || true)
            if [ -z "$desc" ]; then
                desc=$(grep '^name:' "$f" 2>/dev/null | head -1 | sed 's/^name: *//' || true)
            fi
            echo "- [$base]($base) — ${desc:-no description}" >> "$tmp_merged"
        fi
    done

    # Deduplicate by filename (keep the longer description)
    local tmp_dedup
    tmp_dedup=$(mktemp)
    python3 -c "
import re, sys

entries = {}
for line in open('$tmp_merged'):
    line = line.strip()
    m = re.match(r'- \[([^\]]+)\]', line)
    if m:
        fname = m.group(1)
        # Keep the longer (presumably more descriptive) entry
        if fname not in entries or len(line) > len(entries[fname]):
            entries[fname] = line

for line in sorted(entries.values()):
    print(line)
" > "$tmp_dedup"

    # Write merged MEMORY.md
    cat > "$tgt_index" <<HEADER
# Memory Index

HEADER
    cat "$tmp_dedup" >> "$tgt_index"
    echo "" >> "$tgt_index"

    rm -f "$tmp_merged" "$tmp_dedup"
    info "MEMORY.md index merged and deduplicated"
}

# Run MEMORY.md merge if either side has one
if [ -f "$SOURCE_DIR/MEMORY.md" ] || [ -f "$TARGET_DIR/MEMORY.md" ]; then
    merge_memory_index
fi

echo ""
ok "Merge complete: $MERGED added, $SKIPPED unchanged, $CONFLICTS conflicts"
if [ "$CONFLICTS" -gt 0 ]; then
    warn "Review *_conflict.md files in $TARGET_DIR and merge manually"
fi
