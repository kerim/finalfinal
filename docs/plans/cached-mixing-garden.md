# Fix publish.sh duplicate commit bug

## Context

`scripts/publish.sh` filters private files (docs/, CLAUDE.md, .claude/, test-data/) from commits before pushing to GitHub. It uses `origin/main..main` to find commits to filter, but after pushing, `origin/main` points to *filtered* commits not in local `main`'s ancestry. Each run re-filters ALL local commits since the common ancestor, duplicating them on the remote.

Current state:
- Local `main`: 4 commits ahead of common ancestor (24441bb)
- Remote `origin/main`: 6 commits ahead — same 2 commits filtered 3 times each
- Common ancestor: 24441bb (Merge branch 'focus-prefs')

## Fix

**Track the last local commit that was filtered** using a git ref `refs/publish/last-local`.

Changes to `scripts/publish.sh`:

1. **After fetch**, read the tracking ref: `git rev-parse --verify refs/publish/last-local 2>/dev/null`
2. **If tracking ref exists**, use it for the range: `$LAST_LOCAL..main` (instead of `origin/main..main`)
3. **If tracking ref doesn't exist** (first run or migration), fall back to `merge-base main origin/main` as the starting point, and force-push to clean up duplicates
4. **After successful push**, store local main tip: `git update-ref refs/publish/last-local $(git rev-parse main)`
5. **Migration handling**: detect diverged state (tracking ref missing + origin/main diverged from main), warn user, and require `--force` flag to clean up the remote

### One-time cleanup

The first run with the fix will:
- Detect no tracking ref exists
- Find merge-base (24441bb)
- Filter commits from 24441bb..main (4 commits)
- Chain filtered commits onto 24441bb (which exists on both local and remote)
- Force push to replace the duplicated remote history
- Set the tracking ref to current local main tip

## Files to modify

- `scripts/publish.sh` — the only file changed

## Verification

1. Run `git log --oneline origin/main -10` before fix — see duplicate commits
2. Run `scripts/publish.sh --force` to do the one-time cleanup
3. Run `git log --oneline origin/main -10` after — no duplicates
4. Add a test commit locally, run `scripts/publish.sh` again
5. Verify only the new commit appears on origin/main (no re-duplication)
6. Check fish prompt shows ↓0 after publish (no "behind" count)
