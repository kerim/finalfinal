# Fix release.sh changelog handling

## Context

`scripts/release.sh` step 4 looks for a `## [$VERSION]` section in CHANGELOG.md but ignores content under `## [Unreleased]` — which is where changelog entries are actually drafted (per Keep a Changelog convention). The script falls through to an interactive BBEdit step that fails when run non-interactively, aborting the release.

Current state: version is 0.2.54, last release is v0.2.52, and CHANGELOG.md has substantial content under `## [Unreleased]` that should have been used.

## Fix

Change the changelog lookup order in `scripts/release.sh` (lines 46-96):

1. **First**, check for `## [$VERSION]` (existing behavior — keeps working if someone pre-creates versioned entry)
2. **Second**, check for non-empty content under `## [Unreleased]` — if found, use it directly (no editor)
3. **Third** (fallback), draft from commits and open editor

When using `## [Unreleased]` content:
- Extract everything between `## [Unreleased]` and the next `## [` header
- Stamp it with `## [$VERSION] - $DATE` in CHANGELOG.md
- Add a fresh empty `## [Unreleased]` section above it
- Commit the changelog update
- Skip the BBEdit step entirely

This matches how Keep a Changelog is meant to work: accumulate entries under Unreleased, then promote at release time.

## File to modify

- `scripts/release.sh` — rewrite lines 46-96 (Step 4 changelog logic)

## Verification

1. Ensure CHANGELOG.md has content under `## [Unreleased]`
2. Run `scripts/release.sh` — should pick up Unreleased content automatically, no editor prompt
3. Check CHANGELOG.md after: new `## [0.2.54] - 2026-02-26` section with the content, fresh empty `## [Unreleased]` above it
4. Verify the GitHub release has correct notes
