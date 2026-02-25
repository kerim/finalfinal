#!/bin/bash
#
# protect-backups-git.sh - Block git rm on .backups/ folder
#
# PreToolUse hook for Bash tool. Prevents git rm commands that
# target .backups/ directories.
#
# Exit codes:
#   0 = allow the operation
#   2 = block with error message

# Read JSON input from stdin
input=$(cat)

# Extract the command from the tool input
command=$(echo "$input" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

# Check if it's a git rm targeting .backups
if echo "$command" | grep -qE "git\s+rm.*\.backups"; then
    echo "BLOCKED: Cannot git rm files in .backups/ folder" >&2
    exit 2
fi

# Check if it's a git operation targeting the external backup location
if echo "$command" | grep -qE "git\s+(rm|add|mv).*Claude Code Plans Backups"; then
    echo "BLOCKED: Cannot run git operations on Claude Code Plans Backups folder" >&2
    exit 2
fi

# Allow the operation
exit 0
