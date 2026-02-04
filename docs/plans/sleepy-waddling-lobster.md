# Fix Build Script: Remove Empty _CodeSignature Directory

## Problem

The `codesign --remove-signature` command removes the signature content but leaves an empty `_CodeSignature` directory. macOS interprets this as a corrupted/invalid signature (causing `kLSUnknownErr -10810`) rather than an unsigned app, which prevents the "Open Anyway" option from appearing in Security preferences.

## Solution

Add a line to delete the `_CodeSignature` directory after removing signatures.

## File to Modify

`scripts/build-and-distribute.sh`

## Change

After line 109 (after the signature removal loop), add:

```bash
rm -rf "/Applications/$APP_NAME.app/Contents/_CodeSignature"
```

The updated Step 4.5 section will be:

```bash
# Step 4.5: Remove ad-hoc signature (allows right-click → Open on other Macs)
echo -e "${YELLOW}Step 4.5: Removing ad-hoc signature for distribution...${NC}"
codesign --remove-signature "/Applications/$APP_NAME.app"
# Also remove signatures from embedded frameworks/helpers if any
find "/Applications/$APP_NAME.app" -name "*.framework" -o -name "*.dylib" | while read f; do
    codesign --remove-signature "$f" 2>/dev/null || true
done
# Remove empty _CodeSignature directory (codesign --remove-signature leaves it behind)
rm -rf "/Applications/$APP_NAME.app/Contents/_CodeSignature"
echo -e "${GREEN}  Signature removed${NC}"
```

## Verification

1. Run `ffbuild`
2. Check that `/Applications/final final.app/Contents/_CodeSignature` does not exist
3. Verify app opens (may need to right-click → Open first time)
