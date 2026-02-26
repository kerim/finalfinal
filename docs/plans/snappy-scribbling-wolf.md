# Fix: ffrelease version grep matches multiple lines

## Context

`ffrelease` fails because `release.sh` reads the version with `grep 'CURRENT_PROJECT_VERSION:'` which now matches **two** lines in `project.yml` (main app target on line 70, Quick Look extension on line 133). This embeds a newline in `$VERSION`, producing an invalid zip path. The build script already handles this correctly with `grep -m1`.

## Change

**File:** `scripts/release.sh` line 32

```bash
# Before
VERSION=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)"/\1/')

# After
VERSION=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)"/\1/')
```

Single character change: add `-m1` flag to match only the first occurrence, consistent with `build.sh`.

## Verification

1. Run `ffrelease` — it should get past Step 2 without the "Zip not found" error
2. Confirm the version prints as a single line: `Step 2: Version is 0.2.55`
