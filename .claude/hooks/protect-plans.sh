#!/bin/bash
#
# protect-plans.sh - Backup plan files before editing
#
# PreToolUse hook for Write/Edit tools. Creates timestamped backup
# of existing plan files before allowing modifications.
#
# Exit codes:
#   0 = allow the operation (after backup if needed)
#   2 = block with error message

# Read JSON input from stdin
input=$(cat)

# Extract the file path from the tool input
file_path=$(echo "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

# If no file path found, allow
[ -z "$file_path" ] && exit 0

# Check if this is a plan file
plans_dir="$CLAUDE_PROJECT_DIR/docs/plans"

case "$file_path" in
    "$plans_dir"/* | ./docs/plans/* | docs/plans/*)
        # Handle relative paths
        if [[ "$file_path" == ./* ]]; then
            full_path="$CLAUDE_PROJECT_DIR/${file_path:2}"
        elif [[ "$file_path" != /* ]]; then
            full_path="$CLAUDE_PROJECT_DIR/$file_path"
        else
            full_path="$file_path"
        fi

        # If file exists, create backup before allowing edit
        if [ -f "$full_path" ]; then
            # Get current git branch (sanitize for filesystem)
            branch=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
            branch_safe=$(echo "$branch" | tr '/' '-')

            # External backup location organized by branch
            backup_dir="/Users/niyaro/Documents/Code/Claude Code Plans Backups/$branch_safe"
            mkdir -p "$backup_dir"

            filename=$(basename "$full_path")
            timestamp=$(date +%Y%m%d-%H%M%S)
            cp "$full_path" "$backup_dir/${filename%.md}-${timestamp}.md"
            echo "Backed up to: $backup_dir/${filename%.md}-${timestamp}.md" >&2
        fi
        ;;
esac

# Allow the operation
exit 0
