# QuickLook Extension Not Loading

**Symptom:** Finder shows blank placeholder instead of rendered preview for .ff files. `qlmanage -p` produces no preview content.

**Version:** v0.2.55 through v0.2.56

---

## Root Causes

### 1. QLSupportsSecureCoding Missing from Built Info.plist

The source `QuickLook Extension/Info.plist` had `QLSupportsSecureCoding: true`, but the **built** plist did not.

**Why:** xcodegen rewrites the source plist from `project.yml`'s `info.properties` on every `xcodegen generate`. The NSExtension dict was defined in project.yml, and during earlier iterations, the boolean value was being dropped during the YAML-to-plist conversion.

**Fix:** Ensured NSExtension (with QLSupportsSecureCoding) is declared in `project.yml` info.properties. Verified the boolean survives the full xcodegen + xcodebuild pipeline by checking the built plist.

**Verification:** `grep QLSupportsSecureCoding "/Applications/FINAL|FINAL.app/Contents/PlugIns/QuickLook Extension.appex/Contents/Info.plist"` must return a match.

### 2. Stale pluginkit Registration from DerivedData

`pluginkit -v -m -i com.kerim.final-final.quicklook` showed the extension registered from:
```
/Users/niyaro/Library/Developer/Xcode/DerivedData/final_final-.../Build/Products/Debug/...
```
This was an old Xcode IDE build. The build script uses `-derivedDataPath "$PROJECT_DIR/build"` (custom path), so the /Applications copy is the correct one.

**Fix:** Added `pluginkit -r` before build (removes stale registrations) and `pluginkit -a` after signing (registers the /Applications copy).

### 3. System Falling Back to Package.qlgenerator

Because the extension wasn't recognized as a QuickLook preview provider, macOS used the built-in `Package.qlgenerator` for `com.kerim.final-final.document` (which conforms to `com.apple.package`).

**Fix:** Resolved by fixes #1 and #2 above. Once the extension is properly registered with QLSupportsSecureCoding, it takes priority over Package.qlgenerator.

---

## Diagnostic Commands

```bash
# Check if extension is registered as a preview provider
pluginkit -m -p com.apple.quicklook.preview | grep final

# Check where the extension is registered from
pluginkit -v -m -i com.kerim.final-final.quicklook

# Check which handler owns the content type
qlmanage -m | grep final-final

# Test preview rendering
qlmanage -p "/path/to/file.ff"

# Check built plist for required keys
grep QLSupportsSecureCoding "/Applications/FINAL|FINAL.app/Contents/PlugIns/QuickLook Extension.appex/Contents/Info.plist"
```

---

## Files Changed

| File | Change |
|------|--------|
| `project.yml` | NSExtension kept in info.properties (xcodegen rewrites source plist) |
| `scripts/build.sh` | Added `pluginkit -r` before build, `pluginkit -a` after signing |
