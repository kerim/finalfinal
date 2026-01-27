# Plan: Move Claude Code Plan Backups Outside Git Repository

## Problem

The current backup location `docs/plans/.backups/` is inside the git repository and gets cleared during git merge operations, causing loss of backup files.

## Solution

Move backups to an external location organized by branch:
- **Base directory:** `/Users/niyaro/Documents/Code/Claude Code Plans Backups/`
- **Branch subdirectories:** One folder per git branch (e.g., `main/`, `feature-x/`)
- **Filename format:** `<planname>-YYYYMMDD-HHMMSS.md`

## Files to Modify

### 1. `.claude/hooks/protect-plans.sh`

**Changes:**
- Replace `backup_dir="$CLAUDE_PROJECT_DIR/docs/plans/.backups"` with external path
- Add git branch detection: `branch=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")`
- Sanitize branch name for filesystem (replace `/` with `-`)
- Create backup directory: `/Users/niyaro/Documents/Code/Claude Code Plans Backups/<branch>/`

### 2. `.claude/hooks/protect-backups.sh`

**Changes:**
- Update path pattern to protect `/Users/niyaro/Documents/Code/Claude Code Plans Backups/*`
- Keep `.backups/` protection for backwards compatibility

### 3. `.claude/hooks/protect-backups-git.sh`

**Changes:**
- Update pattern to also block git operations on the new backup location

### 4. `docs/hooks.md`

**Changes:**
- Update documentation to reflect new backup location
- Document branch-based organization

## Verification

1. Edit any plan file → Backup should appear in `/Users/niyaro/Documents/Code/Claude Code Plans Backups/<current-branch>/`
2. Switch branches → Backups should go to the appropriate branch subfolder
3. Perform git merge → External backups should remain untouched
4. Attempt to modify backup files → Should be blocked by hooks
