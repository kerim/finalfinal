# Plan: Protect .backups Folder

## Problem

The `.backups/` folder can be deleted by Claude or git operations, defeating the purpose of having backups.

## Solution

### Task 1: Create hook to block deletions in .backups/

Create `.claude/hooks/protect-backups.sh`:

```bash
#!/bin/bash
# Block any Write/Edit operations that would delete files in .backups/

input=$(cat)
file_path=$(echo "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

[ -z "$file_path" ] && exit 0

# Block if path is in .backups
case "$file_path" in
    */.backups/* | */.backups)
        echo "BLOCKED: Cannot modify files in .backups/ folder" >&2
        exit 2
        ;;
esac

exit 0
```

### Task 2: Create hook to block git rm on .backups/

Create `.claude/hooks/protect-backups-git.sh`:

```bash
#!/bin/bash
# Block git rm commands that target .backups/

input=$(cat)
command=$(echo "$input" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

# Check if it's a git rm targeting .backups
if echo "$command" | grep -qE "git\s+rm.*\.backups"; then
    echo "BLOCKED: Cannot git rm files in .backups/ folder" >&2
    exit 2
fi

exit 0
```

### Task 3: Update settings.local.json

Add both hooks:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/protect-plans.sh" },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/protect-backups.sh" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/protect-backups-git.sh" }
        ]
      }
    ]
  }
}
```

### Task 4: Remove .backups from .gitignore (if present)

Check and remove any gitignore rule for .backups.

### Task 5: Commit .backups to git

```bash
git add docs/plans/.backups/
git commit -m "chore: track .backups folder for plan file protection"
```

## Files to Modify

| File | Action |
|------|--------|
| `.claude/hooks/protect-backups.sh` | Create - blocks Write/Edit to .backups |
| `.claude/hooks/protect-backups-git.sh` | Create - blocks git rm on .backups |
| `.claude/settings.local.json` | Update - add new hooks |
| `.gitignore` | Check/update - ensure .backups not ignored |
| `docs/plans/.backups/*` | Add to git |

## Verification

1. Try to edit a file in .backups/ → Should be BLOCKED
2. Try `git rm docs/plans/.backups/somefile.md` → Should be BLOCKED
3. Run `git status` → .backups files should be tracked
4. Edit a plan file → Backup should be created AND committed
