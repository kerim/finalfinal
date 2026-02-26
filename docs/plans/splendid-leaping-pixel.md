# Fix build.sh version parsing for multiple CURRENT_PROJECT_VERSION entries

## Context

`scripts/build.sh` fails because `project.yml` has two `CURRENT_PROJECT_VERSION:` entries — one for the main app target (line 70) and one for the QuickLook Extension target (line 133). The `grep` on line 30 returns both lines, so the version variables contain two-line values (e.g., `54\n54`), which breaks the arithmetic on line 39.

## Fix

**File:** `scripts/build.sh`, line 30

Change:
```bash
CURRENT_VERSION=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)"/\1/')
```

To:
```bash
CURRENT_VERSION=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)"/\1/')
```

`grep -m1` stops after the first match, so `CURRENT_VERSION` will be `0.2.54` instead of `0.2.54\n0.2.54`.

The `sed` commands on lines 44 and 48 are fine — they replace all occurrences in their respective files, which is the desired behavior (both targets should stay in sync).

## Verification

Run `ffbuild` and confirm:
- Version increments correctly (0.2.54 → 0.2.55)
- Both `CURRENT_PROJECT_VERSION` entries in `project.yml` get updated
- `web/package.json` version gets updated
- Build proceeds past Step 1
