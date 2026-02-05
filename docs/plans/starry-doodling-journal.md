# Fix ffbuild Script for FINAL|FINAL Rebrand

## Problem

The `ffbuild` command fails after the build succeeds:
```
** BUILD SUCCEEDED **
Error: Build failed - app not found at .../Debug/final final.app
```

## Root Cause

The app was rebranded from "final final" to "FINAL|FINAL" (commit 8b54566), but the build script wasn't updated:

- **project.yml line 39:** `PRODUCT_NAME: FINAL|FINAL`
- **build-and-distribute.sh line 20:** `APP_NAME="final final"` ← wrong

The xcodebuild output goes to `FINAL|FINAL.app`, but the script looks for `final final.app`.

## Fix

Update `/Users/niyaro/Documents/Code/final final/scripts/build-and-distribute.sh`:

Change line 20 from:
```bash
APP_NAME="final final"
```

To:
```bash
APP_NAME="FINAL|FINAL"
```

## Verification

After the fix:
1. Run `ffbuild`
2. Build should complete without "app not found" error
3. App should be installed to `/Applications/FINAL|FINAL.app`
4. Zip should be created as `FINAL|FINAL.zip` in iCloud share folder
