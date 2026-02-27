# QuickLook Extension Fix — v04 (post-build diagnosis)

## Context

The v03 plan's code changes (try! fix, SQLite path fix, security-scoped access, logging, build script hardening) have been **implemented and built**, but the preview still shows a blank placeholder. Post-build diagnostics revealed two new root causes preventing the extension from loading.

## Diagnosis

### Finding 1: QLSupportsSecureCoding stripped from built Info.plist

The source `QuickLook Extension/Info.plist` has `QLSupportsSecureCoding: true` inside `NSExtensionAttributes`, but the **built** Info.plist (both DerivedData and /Applications copies) does NOT have it.

**Cause:** `project.yml` defines `info.properties.NSExtension` which xcodegen merges into the source plist. During this merge, xcodegen appears to drop the boolean `QLSupportsSecureCoding: true` value (YAML boolean → plist boolean conversion issue in nested dicts). The xcode project.pbxproj has NO `INFOPLIST_KEY_*` entries for the extension target, confirming xcodegen handles NSExtension through plist rewriting rather than build settings.

**Evidence:** `grep -c QLSupportsSecureCoding` on `/Applications/...appex/Contents/Info.plist` returns 0, while the source plist has it at line 31.

**Impact:** Without `QLSupportsSecureCoding`, the system does not recognize the extension as a valid QuickLook preview provider.

### Finding 2: Stale pluginkit registration from DerivedData

`pluginkit -v -m -i com.kerim.final-final.quicklook` shows the extension registered from:
```
/Users/niyaro/Library/Developer/Xcode/DerivedData/final_final-.../Build/Products/Debug/...
```
NOT from `/Applications/FINAL|FINAL.app/...`. This is an older build (v0.2.55) from a previous Xcode IDE run. The build script's `xcodebuild` uses `-derivedDataPath "$PROJECT_DIR/build"` (custom path), so the /Applications copy is the only correct one.

### Finding 3: System using Package.qlgenerator instead

`qlmanage -m` shows:
```
com.kerim.final-final.document -> /System/Library/QuickLook/Package.qlgenerator (1018.3.2 - loaded)
```
Because our extension isn't registered as a QuickLook preview provider, the built-in Package handler intercepts the content type (which conforms to `com.apple.package`).

`pluginkit -m -p com.apple.quicklook.preview` does NOT list our extension — confirming it's not recognized as a preview provider.

## Fix Plan

### 1. Remove NSExtension from project.yml info.properties

**File:** `project.yml`, lines 143-149

Remove the entire `NSExtension` block from the QuickLook Extension target's `info.properties`. The source `Info.plist` already has the complete, correct NSExtension dict (including `QLSupportsSecureCoding`). Removing it from project.yml prevents xcodegen from interfering with the source plist's NSExtension dict.

**Before:**
```yaml
    info:
      path: QuickLook Extension/Info.plist
      properties:
        CFBundleDisplayName: FINAL|FINAL Quick Look
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        NSExtension:
          NSExtensionPointIdentifier: com.apple.quicklook.preview
          NSExtensionPrincipalClass: QuickLook_Extension.PreviewViewController
          NSExtensionAttributes:
            QLSupportedContentTypes:
              - com.kerim.final-final.document
            QLSupportsSecureCoding: true
```

**After:**
```yaml
    info:
      path: QuickLook Extension/Info.plist
      properties:
        CFBundleDisplayName: FINAL|FINAL Quick Look
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
```

### 2. Verify QLSupportsSecureCoding survives xcodegen + build

After `xcodegen generate`, confirm the source Info.plist still has `QLSupportsSecureCoding`. If xcodegen removes keys not present in properties, we'll need to add a post-generate step to restore it.

### 3. Add extension registration to build script

**File:** `scripts/build.sh`, after the signing step

Add explicit pluginkit registration from /Applications to ensure the system uses the correct copy:

```bash
# Step 4b: Register QuickLook extension
echo "  Registering QuickLook extension..."
pluginkit -a "$APPEX_PATH"
```

### 4. Clean stale DerivedData registration

Before building, remove the stale registration pointing to DerivedData:

```bash
# Clean stale extension registrations (DerivedData leftovers)
pluginkit -r -i com.kerim.final-final.quicklook 2>/dev/null || true
```

## Build & Test Sequence

1. `pluginkit -r -i com.kerim.final-final.quicklook` — remove stale registration
2. `rm -rf "/Applications/FINAL|FINAL.app"` — remove old install
3. `qlmanage -r && qlmanage -r cache` — reset QuickLook
4. Make the project.yml and build.sh edits
5. `xcodegen generate`
6. **Verify:** `grep QLSupportsSecureCoding "QuickLook Extension/Info.plist"` — must return a match
7. Run `scripts/build.sh`
8. **Verify:** `grep QLSupportsSecureCoding "/Applications/FINAL|FINAL.app/Contents/PlugIns/QuickLook Extension.appex/Contents/Info.plist"` — must return a match
9. Open FINAL|FINAL app once (Launch Services registers UTType)
10. `qlmanage -r && qlmanage -r cache`
11. `pluginkit -m -p com.apple.quicklook.preview | grep final` — extension should now appear
12. `qlmanage -p "/Users/niyaro/Documents/final final Projects/Demo.ff"` — should show rendered preview
13. Check Console.app for `com.kerim.final-final.quicklook` Logger entries

## Critical Files

| File | Change |
|------|--------|
| `project.yml:143-149` | Remove NSExtension from info.properties |
| `scripts/build.sh` | Add pluginkit -a after signing, pluginkit -r before build |
