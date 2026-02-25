# Review: clever-cuddling-whistle (Filtered Publish Workflow)

## Summary

The plan proposes re-tracking private files in git (for worktree support) and introducing a `publish.sh` script that uses git plumbing to create filtered commits excluding private files, pushing those to `origin/main`. This is a sound approach to a real limitation of `.gitignore`-based exclusion.

## Findings

### 1. release.sh line numbers are correct

**Confidence: High**

The plan references line 100 (`git tag`) and line 106 (`git push origin main --tags`). Verified against the actual file at `/Users/niyaro/Documents/Code/final final/scripts/release.sh`:

- Line 100: `git tag "v${VERSION}"` -- matches the plan's "Before" exactly
- Line 106: `git push origin main --tags` -- matches the plan's "Before" exactly

The proposed changes are:
- Line 100: `git tag "v${VERSION}" public` -- tags the public ref
- Line 106: Replace with `./scripts/publish.sh` + `git push origin "v${VERSION}"`

These are accurate references.

### 2. Bootstrap problem: "public" ref will not exist on first run

**Confidence: High -- this is a real issue**

Currently `git rev-parse public` fails ("ref 'public' does not exist"). The plan's `publish.sh` description says it "Compares main against origin/main to find unpublished commits" and "chains filtered commits linearly on the public ref." But the script description does not address how the `public` ref is initialized on the very first invocation.

Two sub-issues:

**(a) First run of `publish.sh`:**
The script needs to create the `public` ref from scratch. If it walks `origin/main..main` and builds filtered commits chained on `origin/main`, this should work -- the parent of the first filtered commit is `origin/main` (which already exists). The script just needs to not assume `public` already exists as a starting point. The plan should explicitly state that on first run, the chain starts from `origin/main` (not from `public`).

**(b) `release.sh` line 100 -- `git tag "v${VERSION}" public`:**
If `publish.sh` is called on line 106 *after* the tag on line 100, the tag would reference a `public` ref that doesn't yet exist (first run) or points to a stale value (subsequent runs where publish.sh updates it). The tag must be created *after* `publish.sh` runs.

**Recommendation:** In the plan's release.sh changes, swap the order so `publish.sh` runs first, then tag:
```bash
# Push first (creates/updates public ref)
./scripts/publish.sh
# Tag the now-updated public ref
git tag "v${VERSION}" public
# Push the tag
git push origin "v${VERSION}"
```

This is not just a "nice to have" -- the current plan order would tag a stale or nonexistent ref.

### 3. Tag placement: tags must point to commits on origin/main

**Confidence: High**

The plan correctly identifies that tags should point to `public` (filtered commits) rather than `main` (which contains private files). When someone fetches `v0.2.53` from GitHub, the tag must resolve to a commit that exists in `origin/main`'s history. Using `git tag "v${VERSION}" public` achieves this, provided the ordering fix from Finding 2 is applied.

One additional concern: `gh release create` on line 112 uses `"v${VERSION}"` as the tag. GitHub will look for this tag on the remote. Since the plan pushes the tag separately with `git push origin "v${VERSION}"`, the tag needs to be pushed *before* `gh release create` runs. The proposed order in the plan (publish.sh, then push tag, then gh release create) is correct for this, assuming the tag creation is moved after publish.sh as recommended above.

### 4. Race conditions and failure modes

**Confidence: Medium-High**

**(a) Partial failure in publish.sh:**
If `publish.sh` fails mid-way (e.g., after creating some filtered commits but before updating the `public` ref), the next run would need to be idempotent. Since the script creates new tree objects and commits via plumbing commands, and only updates `public` at the end (presumably with `git update-ref`), a crash before the final update-ref is safe -- git objects are created but unreferenced and will be garbage-collected. This is a good design.

**(b) publish.sh succeeds but push fails:**
If `git push origin public:main` fails (network error, force-push protection, etc.), the local `public` ref is ahead of `origin/main`. The next run of publish.sh would see `origin/main..main` has the same commits, recreate the same filtered commits, and try again. This should be fine as long as the script doesn't assume `public` and `origin/main` are in sync. The plan should clarify whether publish.sh checks `public` or `origin/main` as its base.

**(c) Concurrent builds:**
Not a practical concern for a single-developer project. No issue here.

**(d) Merge commit linearization:**
The plan says "Merge commits are linearized (single parent from public chain) -- content is still correct." This is acceptable for this use case. The filtered public history will have linear topology even when `main` has merges. The tree content at each commit is correct because the filtering is tree-level, not diff-level.

### 5. build.sh auto-commit interaction

**Confidence: High -- no issue found**

`build.sh` (line 117-122) auto-commits the version bump to `main`:
```bash
git add project.yml web/package.json "final final.xcodeproj/project.pbxproj"
git commit -m "Build v${NEW_VERSION}"
```

This creates a normal commit on `main`. The next time `publish.sh` runs, it will pick up this commit (since it's in `main` but not yet in `origin/main`), filter it, and push the filtered version. The files committed by build.sh (`project.yml`, `web/package.json`, `project.pbxproj`) are not private files, so the filtered commit will be identical in content.

The workflow `build.sh` then `release.sh` works correctly:
1. `build.sh` commits version bump to `main`
2. `release.sh` creates changelog commit on `main`
3. `release.sh` calls `publish.sh` which filters both commits and pushes to `origin/main`
4. Tag is created on `public` ref, pushed, GitHub release created

No interaction problem.

### 6. Other locations that push to origin

**Confidence: High**

Searched the entire project for `git push`. The only occurrence is in `/Users/niyaro/Documents/Code/final final/scripts/release.sh` at line 106. There are no GitHub Actions workflows (`.github/` directory does not exist), no other scripts that push, and `build.sh` only commits locally.

Step 1 of the plan proposes a one-time `git push origin main` to push the 4 clean commits. This is a manual command, not in a script, so it doesn't create a recurring issue. After the publish workflow is established, all future pushes go through `publish.sh`.

### 7. Plan accuracy: the "4 clean unpushed commits" claim

**Confidence: High -- verified**

The plan claims commits `56d50dd..24441bb` (4 commits) are clean of private files. I verified:
- `origin/main` is at `3085781`
- The 4 commits between `origin/main` and `main` are: `56d50dd`, `056dc76`, `54231ef`, `24441bb`
- `git diff 3085781..24441bb --stat` shows no changes to `docs/`, `CLAUDE.md`, `.claude/`, or `test-data/`

The plan is correct that these can be pushed directly.

### 8. .gitignore changes look correct

**Confidence: High**

The plan removes `docs/`, `CLAUDE.md`, `.claude/`, `test-data/` from `.gitignore` and adds:
```
.claude/worktrees/
.claude/settings.local.json
.claude/debug/
```

This is sensible. The narrow exclusions cover:
- `worktrees/` -- ephemeral, machine-specific
- `settings.local.json` -- machine-specific overrides
- `debug/` -- runtime debug output

One minor note: `.claude/hooks/` and `.claude/skills/` and `.claude/settings.json` would now be tracked, which is the intent. The `git add` command in Step 3 explicitly lists these paths, which is good practice rather than a blanket `git add .claude/`.

### 9. Missing detail: the actual publish.sh script

**Confidence: Medium**

The plan describes `publish.sh` conceptually (Step 4) but does not include the actual script. It mentions:
- Uses `git ls-tree`, `git mktree`, `git commit-tree`
- Filters out `docs/`, `CLAUDE.md`, `.claude/`, `test-data/`
- Preserves original authorship/dates
- Pushes `public` to `origin/main`

The description is sufficient for implementation, but the following details should be pinned down in the script:

**(a) Filter list maintenance:** The list of excluded paths (`docs/`, `CLAUDE.md`, `.claude/`, `test-data/`) is hardcoded in the script. If new private directories are added later, the script must be updated. Consider adding a comment in publish.sh listing the excluded paths, and a note in CLAUDE.md about updating publish.sh when adding new private directories.

**(b) Push command specifics:** The script should use `git push origin public:main` (pushspec syntax) to push the local `public` ref to the remote `main` branch. The plan mentions "Pushes public to origin/main" but the exact refspec matters.

**(c) Error handling:** The script should `set -e` and verify that `origin/main` is an ancestor of the new `public` ref before pushing (to avoid accidental force-pushes if history diverges).

## Issue Summary

| # | Category | Severity | Description |
|---|----------|----------|-------------|
| 1 | Tag ordering in release.sh | Critical | Tag is created before publish.sh runs, so it references a stale/nonexistent `public` ref. Must swap order. |
| 2 | Bootstrap case not documented | Important | Plan should explicitly state how `public` ref is initialized on first run (chain starts from `origin/main`). |
| 3 | Push failure recovery | Suggestion | Clarify whether publish.sh uses `public` or `origin/main` as its chain base, to handle the case where a previous push failed. |
| 4 | Filter list maintenance | Suggestion | Add a note about keeping publish.sh's exclusion list in sync when new private directories are added. |
| 5 | Force-push guard | Suggestion | publish.sh should verify `origin/main` is an ancestor of the new `public` before pushing. |

## What the Plan Gets Right

- The core approach is sound: git plumbing for tree-level filtering is the right tool for "track locally, exclude from remote."
- Correctly identifies that the 4 unpushed commits are clean and can be pushed directly.
- The `.gitignore` changes are well-scoped with appropriate narrow exclusions for `.claude/` subdirectories.
- Merge commit linearization is an acceptable trade-off for this project's needs.
- No interaction issues with `build.sh` auto-commits.
- The single `git push` call in the codebase is correctly identified and updated.

## Recommended Plan Revision

The only critical fix needed is the tag ordering in the release.sh modifications (Finding 2). The release.sh section (Step 5) should read:

**Line 100** -- Remove the existing tag line entirely.

**Line 106** -- Replace with:
```bash
./scripts/publish.sh
git tag "v${VERSION}" public
git push origin "v${VERSION}"
```

This ensures the tag is created after `publish.sh` has updated the `public` ref.
