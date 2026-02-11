# Project Hooks

This project uses two types of hooks: **Git hooks** (standard git automation) and **Claude Code hooks** (Claude Code session automation).

---

## Git Hooks

Located in `.git/hooks/` (not tracked in git).

### post-merge

**File:** `.git/hooks/post-merge`

**Triggers:** After any `git merge` or `git pull`

**Purpose:** Rebuilds web editor bundles after merging code changes.

**Why it exists:** The web bundles (`milkdown.js`, `codemirror.js`) are build artifacts not tracked in git. After merging source code changes from another branch, the bundles need to be rebuilt or the app will use stale JavaScript that doesn't reflect the merged changes.

**What it does:**
```bash
cd web && pnpm build
```

**Note:** Git hooks live in `.git/hooks/` which is not tracked by git. If you clone the repo fresh, you'll need to recreate this hook. Consider copying the hook setup to a script in the repo that can be run after cloning.

---

## Claude Code Hooks

Located in `.claude/settings.local.json` and `.claude/hooks/`.

Claude Code hooks run before or after Claude Code tool executions within a Claude Code session. They protect files and automate backups.

### Configuration

**File:** `.claude/settings.local.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "command": ".claude/hooks/protect-plans.sh" },
          { "command": ".claude/hooks/protect-backups.sh" }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          { "command": ".claude/hooks/protect-backups-git.sh" }
        ]
      }
    ]
  }
}
```

### protect-plans.sh

**File:** `.claude/hooks/protect-plans.sh`

**Triggers:** Before any `Write` or `Edit` tool execution

**Purpose:** Automatically backs up plan files before Claude Code modifies them.

**What it does:**
- Detects if the target file is in `docs/plans/`
- If the file exists, creates a timestamped backup in the external backup location
- Allows the edit to proceed after backup

**Backup Location:** `/Users/niyaro/Documents/Code/Claude Code Plans Backups/<branch>/`

Backups are organized by git branch to keep them separate across different workstreams. The branch name is sanitized (e.g., `feature/foo` becomes `feature-foo`).

**Example:** On branch `main`, editing `docs/plans/feature.md` creates:
`/Users/niyaro/Documents/Code/Claude Code Plans Backups/main/feature-20260124-153022.md`

**Why external location:** The previous location (`docs/plans/.backups/`) was inside the git repository and would get cleared during git merge operations. The external location preserves backups regardless of git operations.

### protect-backups.sh

**File:** `.claude/hooks/protect-backups.sh`

**Triggers:** Before any `Write` or `Edit` tool execution

**Purpose:** Prevents Claude Code from modifying backup files.

**What it does:**
- Blocks any write/edit operation targeting files in `.backups/` directories (backwards compatibility)
- Blocks any write/edit operation targeting files in `/Users/niyaro/Documents/Code/Claude Code Plans Backups/`
- Returns exit code 2 to stop the operation

### protect-backups-git.sh

**File:** `.claude/hooks/protect-backups-git.sh`

**Triggers:** Before any `Bash` tool execution

**Purpose:** Prevents Claude Code from running destructive git commands on backup files.

**What it does:**
- Detects `git rm` commands targeting `.backups/` directories (backwards compatibility)
- Detects `git rm`, `git add`, or `git mv` commands targeting the external backup location
- Blocks such commands with exit code 2

---

## Hook Exit Codes

For Claude Code hooks:
- `0` = Allow the operation
- `2` = Block the operation (with error message to stderr)

---

## Recreating Git Hooks After Clone

After cloning the repository, run:

```bash
cat > .git/hooks/post-merge << 'EOF'
#!/bin/bash
echo "Post-merge: Rebuilding web editors..."
cd "$(git rev-parse --show-toplevel)/web" || exit 0
if command -v pnpm &> /dev/null; then
    pnpm build
    echo "Post-merge: Web editors rebuilt successfully"
else
    echo "Post-merge: WARNING - pnpm not found, skipping web build"
fi
EOF
chmod +x .git/hooks/post-merge
```

Or copy from another checkout of this repository.
