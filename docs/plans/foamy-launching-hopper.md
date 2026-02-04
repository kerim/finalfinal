# Fix Damaged App in Distribution Zip

## Problem

The zip file created by `ffbuild` produces a "damaged app" error when opened on another Mac.

## Root Cause

Two issues combine to cause this:

1. **Ad-hoc code signing** - The app is built with ad-hoc signing (no developer certificate). Ad-hoc signatures are machine-specific and become invalid on other Macs.

2. **Improper zip method** - Using `zip -r` doesn't properly handle macOS app bundles. It can lose extended attributes and doesn't preserve the signature structure correctly.

## Solution

Since you don't have an Apple Developer certificate configured, the fix is to **remove the broken ad-hoc signature entirely** before zipping. An unsigned app can be opened by users (with a right-click → Open), whereas a damaged signature cannot.

### Changes to `scripts/build-and-distribute.sh`

**Before Step 5 (zip creation), add:**

```bash
# Step 4.5: Remove ad-hoc signature (allows right-click → Open on other Macs)
echo -e "${YELLOW}Step 4.5: Removing ad-hoc signature for distribution...${NC}"
codesign --remove-signature "/Applications/$APP_NAME.app"
# Also remove signatures from embedded frameworks/helpers if any
find "/Applications/$APP_NAME.app" -name "*.framework" -o -name "*.dylib" | while read f; do
    codesign --remove-signature "$f" 2>/dev/null || true
done
echo -e "${GREEN}  Signature removed${NC}"
echo ""
```

**Replace the zip command (line 113) with `ditto`:**

```bash
# Use ditto instead of zip - properly handles macOS app bundles
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ICLOUD_SHARE/$APP_NAME.zip"
```

### Why This Works

- `codesign --remove-signature` removes the invalid ad-hoc signature
- An unsigned app triggers a Gatekeeper warning but users can right-click → Open to bypass
- `ditto` is Apple's tool for creating archives and properly handles:
  - Extended attributes
  - Resource forks
  - App bundle structure
  - Symlinks

### User Experience After Fix

When a user downloads and extracts the zip:
1. Double-click shows: "final final can't be opened because Apple cannot check it for malicious software"
2. Right-click → Open → Click "Open" in dialog
3. App runs normally (and is remembered as trusted)

## Files to Modify

| File | Change |
|------|--------|
| `scripts/build-and-distribute.sh` | Add signature removal, replace `zip` with `ditto` |

## Alternative: Proper Code Signing

If you have or obtain an Apple Developer account ($99/year), you could:
1. Add `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` to `project.yml`
2. Build with `-configuration Release`
3. Optionally notarize the app for seamless distribution

This plan addresses the immediate issue without requiring a developer account.

## Verification

After implementing:
1. Run `ffbuild`
2. Copy the zip to another Mac (or a VM)
3. Extract and verify the app opens with right-click → Open
