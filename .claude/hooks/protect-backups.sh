#!/bin/bash
#
# protect-backups.sh - Block modifications to .backups/ folder
#
# PreToolUse hook for Write/Edit tools. Prevents any file operations
# within .backups/ directories to protect backup files.
#
# Exit codes:
#   0 = allow the operation
#   2 = block with error message

# Read JSON input from stdin
input=$(cat)

# Extract the file path from the tool input
file_path=$(echo "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

# If no file path found, allow
[ -z "$file_path" ] && exit 0

# External backup location
backup_base="/Users/niyaro/Documents/Code/Claude Code Plans Backups"

# Block if path is in .backups or external backup location
case "$file_path" in
    */.backups/* | */.backups)
        echo "BLOCKED: Cannot modify files in .backups/ folder" >&2
        exit 2
        ;;
    "$backup_base"/* | "$backup_base")
        echo "BLOCKED: Cannot modify files in Claude Code Plans Backups folder" >&2
        exit 2
        ;;
esac

# Allow the operation
exit 0
