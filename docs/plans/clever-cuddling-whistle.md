# Fix: Track private files in git, exclude from GitHub pushes

## Context

The "Prepare for GitHub publishing" commit (`37460cf`) used `.gitignore` to keep `docs/`, `CLAUDE.md`, `.claude/`, and `test-data/` off GitHub. But `.gitignore` removes files from git entirely, so they're missing from worktrees. The user needs them tracked in git (for worktrees) but excluded from GitHub.

Git doesn't natively support "track locally, don't push." This requires a **two-branch workflow**: `main` has everything tracked, a `public` ref is a filtered mirror that gets pushed to `origin/main`.

## Steps

### 1. Push the 4 clean unpushed commits first

The 4 commits ahead of `origin/main` (`56d50dd`..`24441bb`) don't contain private files (verified -- they were made after the publishing commit). Push them as-is so `origin/main` is caught up before we diverge.

```bash
git push origin main
```

### 2. Update `.gitignore`

Remove the private-file entries. Add narrow exclusions for things that should genuinely be ignored within `.claude/`:

**Remove these lines:**
```
docs/
CLAUDE.md
.claude/
test-data/
```

**Add these lines (under a "Claude Code local" section):**
```
# Claude Code runtime (not project config)
.claude/worktrees/
.claude/settings.local.json
.claude/debug/
```

**File:** `.gitignore`

### 3. Move hooks config from `settings.local.json` to `settings.json`

The hook registrations (`protect-backups.sh`, `protect-backups-git.sh`) and `plansDirectory` are project-level config, but they currently live in `settings.local.json` (which stays gitignored). Move them to `settings.json` so worktrees get the hooks.

**`.claude/settings.json`** -- merge in `hooks` and `plansDirectory` from `settings.local.json`:
```json
{
  "permissions": {
    "allow": [
      "Bash(xcodebuild:*)",
      "Bash(xcodegen:*)",
      "Bash(swift:*)"
    ]
  },
  "sandbox": {
    "additionalWritePaths": [
      "/Users/niyaro/Library/Developer/Xcode/DerivedData",
      "/Users/niyaro/Library/Caches/org.swift.swiftpm",
      "/Users/niyaro/Library/Developer/CoreSimulator",
      "/tmp/claude-501"
    ],
    "network": {
      "allowedHosts": [
        "registry.npmjs.org"
      ]
    }
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/protect-backups.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/protect-backups-git.sh"
          }
        ]
      }
    ]
  },
  "plansDirectory": "./docs/plans"
}
```

**`.claude/settings.local.json`** -- remove `hooks` and `plansDirectory`, keep only user-specific permissions:
```json
{
  "permissions": {
    "allow": [ ... existing allow list stays ... ]
  }
}
```

### 4. Re-add private files to git tracking

```bash
git add docs/ CLAUDE.md .claude/hooks/ .claude/settings.json .claude/skills/ test-data/
git commit -m "Re-track private files for worktree support"
```

Note: `.claude/settings.local.json`, `.claude/worktrees/`, `.claude/debug/` stay gitignored.

### 5. Create `scripts/publish.sh`

A script that replays commits from `main` onto a `public` ref, filtering out private top-level entries (`docs/`, `CLAUDE.md`, `.claude/`, `test-data/`). Uses git plumbing (`git ls-tree` + `git mktree` + `git commit-tree`) to create filtered commits with original authorship/dates preserved.

Key behavior:
- **Base:** Always uses `origin/main` (not `public`) as the chain's starting parent -- this makes the script idempotent after failed pushes
- For each commit in `git rev-list origin/main..main`, creates a new tree excluding private entries
- Chains filtered commits linearly on the `public` ref
- **Bootstrap:** On first run, `public` doesn't exist -- the first filtered commit's parent is `origin/main`
- **Ancestor guard:** Before pushing, verifies `origin/main` is an ancestor of the new `public` tip (prevents accidental force-push if local history was rewritten)
- Pushes `public` to `origin/main`
- Merge commits are linearized (single parent from public chain) -- content is still correct

**File:** `scripts/publish.sh` (new)

### 6. Update `scripts/release.sh`

**Replace lines 98-108** (the tag + push section) with:

```bash
# Publish filtered commits to GitHub
echo -e "${YELLOW}Publishing to GitHub...${NC}"
"$PROJECT_DIR/scripts/publish.sh"
echo -e "${GREEN}  Published${NC}"
echo ""

# Tag the public (filtered) commit, not main
echo -e "${YELLOW}Tagging v${VERSION}...${NC}"
git tag "v${VERSION}" public
echo -e "${GREEN}  Tagged${NC}"
echo ""

# Push the tag
echo -e "${YELLOW}Pushing tag...${NC}"
git push origin "v${VERSION}"
echo -e "${GREEN}  Pushed${NC}"
echo ""
```

**Critical ordering:** `publish.sh` runs FIRST (creates/advances `public` ref), THEN tag is created on `public`, THEN tag is pushed.

**File:** `scripts/release.sh`

## Files to modify

| File | Change |
|------|--------|
| `.gitignore` | Remove `docs/`, `CLAUDE.md`, `.claude/`, `test-data/`; add narrow `.claude/` exclusions |
| `.claude/settings.json` | Add hooks + plansDirectory (moved from settings.local.json) |
| `.claude/settings.local.json` | Remove hooks + plansDirectory (keep user-specific permissions only) |
| `scripts/publish.sh` | **New** -- filtered push script using git plumbing |
| `scripts/release.sh` | Replace tag+push section with publish-first workflow |

## Verification

1. After step 4: `git worktree add /tmp/test-worktree main` -- confirm docs/, CLAUDE.md, .claude/settings.json (with hooks), test-data/ are present
2. After step 5: Run `./scripts/publish.sh` -- confirm origin/main does NOT contain private files
3. Check GitHub web UI to confirm private files are absent
4. Create a new Claude Code worktree -- confirm private files are present and hooks are active
