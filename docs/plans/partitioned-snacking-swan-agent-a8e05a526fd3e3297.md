# QuickLook Extension Fix -- Code Review

## Review Summary

The diagnosis is largely correct. The `codesign --force --deep --sign -` in the build script was indeed the primary cause of the sandbox entitlements being stripped. The proposed fixes are reasonable but have some gaps and one significant concern. Below is a detailed analysis.

---

## 1. Root Cause Diagnosis: Correct

The original `codesign --deep` usage was the confirmed root cause. The `--deep` flag signs all nested code, but does so with the top-level entitlements (or none), effectively stripping the sandbox entitlement from the embedded `.appex`. The system log message "plug-ins must be sandboxed" confirms this.

The fix in `scripts/build.sh` (lines 96-105) is correct: sign inside-out, extension first with its own entitlements, then the main app with its own entitlements. This is the standard approach.

**Verdict: Fix is correct and well-implemented.**

---

## 2. Potential Info.plist Conflict (IMPORTANT)

There is a subtle but potentially significant issue with how the QuickLook Extension's Info.plist is configured.

The `project.yml` QuickLook Extension target has:
```yaml
info:
  path: QuickLook Extension/Info.plist      # Static plist file
  properties:                                 # Generated properties to merge
    NSExtension:
      NSExtensionAttributes:
        QLSupportsSecureCoding: true
```

Meanwhile, the static file at `QuickLook Extension/Info.plist` ALSO contains `QLSupportsSecureCoding`.

With xcodegen, when you specify both `path` (pointing to an existing plist) and `properties`, xcodegen merges the properties into the plist. This means `QLSupportsSecureCoding` is declared in both places. While this should not cause a functional problem (the merge should produce the same result), it creates a maintenance risk: if someone edits only one location, they might not realize the other exists.

More critically, the main app target has `GENERATE_INFOPLIST_FILE: YES` and `INFOPLIST_GENERATION_MODE: GeneratedFile`, but the QuickLook Extension target does NOT have these settings. This means xcodegen handles the QuickLook Extension's Info.plist differently -- it uses the static plist as a base and merges the `properties` on top. This is fine, but it means the static `QuickLook Extension/Info.plist` IS the authoritative source, and the `properties` in `project.yml` override or add to it.

**Recommendation:** Consolidate. Either remove the `NSExtension` block from the static `Info.plist` and rely entirely on xcodegen `properties`, or remove the `properties` from `project.yml` and rely on the static plist. Having both is confusing. Given that the main app uses generated plists, the cleanest approach would be to add `GENERATE_INFOPLIST_FILE: YES` to the extension target too, remove the static `Info.plist`, and let xcodegen handle everything. But this is a low-priority cleanup, not a blocker.

**Severity: Suggestion (nice to have)**

---

## 3. The `com.apple.security.files.user-selected.read-only` Entitlement (CRITICAL CONCERN)

This is the most important item to discuss.

### Current state
The extension entitlements file (`QuickLook Extension/QuickLook Extension.entitlements`) currently has only:
```xml
<key>com.apple.security.app-sandbox</key>
<true/>
```

### The proposal
Add `com.apple.security.files.user-selected.read-only` to allow reading `content.sqlite` inside the `.ff` package.

### Analysis
This entitlement is **probably not the right one** for a QuickLook extension. Here is why:

- `com.apple.security.files.user-selected.read-only` grants access to files the user has **explicitly selected** via an Open panel or drag-and-drop. A QuickLook extension does not present an Open panel -- the system invokes it automatically when the user presses Space or hovers in Finder.

- When macOS invokes a QuickLook extension, **the system itself grants the extension a temporary sandbox extension** for the URL passed to `preparePreviewOfFile(at:completionHandler:)`. The extension should be able to read the file at that URL without any additional entitlements.

- **However**, for package types (directories conforming to `com.apple.package`), the sandbox extension may only grant access to the package directory itself, not necessarily to files within it. This is the key question: does the sandbox extension for a package URL extend to the package's contents?

### What is likely actually needed

For `.ff` files that are directory-based packages, the most likely scenario is:

1. The sandbox extension granted by QuickLook **should** extend to contents within the package (since the entire directory is "the file"). Apple treats packages as opaque file-like entities.

2. If it does NOT extend to contents, `com.apple.security.files.user-selected.read-only` would not help either, because the user did not "select" the file through an Open panel.

3. The correct approach if sandbox access is truly blocked would be `com.apple.security.temporary-exception.files.absolute-path.read-only` with a specific path pattern, or using `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` on the URL before/after reading.

### Recommendation

**Try without `files.user-selected.read-only` first.** After fixing the codesign issue and doing a clean rebuild, test whether the extension can access the package contents. The sandbox extension from the system should suffice for package contents.

If it still fails, add `os_log` diagnostic logging FIRST (as proposed), check whether the error is a sandbox violation, and then apply the correct fix -- which might be calling `url.startAccessingSecurityScopedResource()` before reading.

The `PreviewViewController.swift` should be updated to:
```swift
func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
        if accessing { url.stopAccessingSecurityScopedResource() }
    }
    // ... rest of the method
}
```

This is a defensive measure that costs nothing if the URL is not security-scoped, but enables access if it is.

**Severity: Critical (the proposed entitlement may be wrong; security-scoped resource access is the safer bet)**

---

## 4. Diagnostic Logging (Proposed): Good

Adding `os_log` to `PreviewViewController.swift` is the right call. Without logging, debugging QuickLook extensions is essentially blind -- there is no way to tell if the extension was loaded, where it failed, or what error occurred.

The plan proposes logging at entry, success, and error points. This is sufficient for initial diagnosis.

One addition: also log the result of `url.startAccessingSecurityScopedResource()` if that approach is adopted, so you can see whether the URL was security-scoped.

**Severity: Important (should do)**

---

## 5. Bibliography Block Filtering (Proposed): Fine

The SQL query change from `WHERE isNotes = 0` to `WHERE isNotes = 0 AND isBibliography = 0` is a reasonable improvement. The `isBibliography` column exists in the `block` table schema (added in migration `v8_blocks`, line 232 of `ProjectDatabase.swift`).

However, there is a risk: if a `.ff` file was created before the `v8_blocks` migration, the `block` table might not exist at all. The current code handles this gracefully -- `queryString` returns `nil` if the table does not exist (line 74 of `SQLiteReader.swift`), and the code falls back to the `content` table. Adding `AND isBibliography = 0` does not change this behavior because the entire query would fail if the table is missing.

**One concern:** For databases that DO have the `block` table but were created before the `isBibliography` column was added -- is there a migration gap? Looking at the schema, `isBibliography` was added in the same migration that creates the `block` table (`v8_blocks`), so any database with a `block` table will also have the `isBibliography` column. No issue here.

**Severity: Suggestion (minor improvement, safe to include)**

---

## 6. Duplicate Registration Cleanup

The plan mentions 5 duplicate extension registrations across DerivedData directories. This is a real problem -- macOS can pick any of these stale registrations, and if an older one lacks proper entitlements or has a stale Info.plist, previews will fail.

### Recommended cleanup procedure

```bash
# 1. Kill QuickLook processes
killall QuickLookSatellite 2>/dev/null
killall quicklookd 2>/dev/null

# 2. Remove ALL DerivedData builds
rm -rf ~/Library/Developer/Xcode/DerivedData/final_final-*

# 3. Remove the stale /Applications install
rm -rf "/Applications/FINAL|FINAL.app"

# 4. Reset QuickLook registrations
qlmanage -r
qlmanage -r cache

# 5. Rebuild from scratch
cd /path/to/project
xcodegen generate
xcodebuild clean -scheme "final final" -destination 'platform=macOS'
# Then build + install via build.sh

# 6. After install, verify single registration
pluginkit -mDAD -p com.apple.quicklook.preview | grep "final-final"
```

The plan's verification step of checking `codesign -d --entitlements -` on the installed `.appex` is also important.

**Severity: Critical (multiple registrations can cause unpredictable behavior)**

---

## 7. Code Quality Review of Extension Files

### PreviewViewController.swift

**What is done well:**
- Clean separation: SQLiteReader reads data, MarkdownRenderer renders it, PreviewViewController composes them
- Error handling shows a user-friendly message instead of crashing
- Proper use of NSScrollView + NSTextView for scrollable content

**Issues found:**

1. **(Important)** The error handler on line 48 passes `nil` to the completion handler instead of the actual error. This means QuickLook never knows the preview failed -- it shows the "Unable to preview" text in the view but reports success to the system. While this may be intentional (to avoid QuickLook falling back to a generic icon), it should be documented with a comment explaining the rationale. If the intent is to show a fallback, this is fine. If not, passing the error would let the system display its own error UI.

2. **(Suggestion)** Missing `import os` for the planned `os_log` additions.

3. **(Critical)** Missing `url.startAccessingSecurityScopedResource()` as discussed in section 3 above.

### SQLiteReader.swift

**What is done well:**
- Uses `immutable=1` URI mode -- excellent for read-only access, prevents SQLite from creating journal/WAL files (which would fail in a sandboxed read-only context)
- Uses `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` flags -- correct combination
- Graceful fallback from `block` table to `content` table for older databases
- Proper cleanup with `defer { sqlite3_close(db) }`
- Error handling with descriptive error types

**Issues found:**

1. **(Suggestion)** The `group_concat` query uses `char(10) || char(10)` as separator (double newline). This is correct for markdown block boundaries, but if any `markdownFragment` already ends with a newline, you could get triple newlines. This is minor -- markdown renderers handle extra whitespace fine.

2. **(Suggestion)** Consider adding a `LIMIT` to the block query for the preview. For very large documents, concatenating all blocks could be slow and produce a very long preview. A `LIMIT 50` or similar would keep previews snappy.

### MarkdownRenderer.swift

**What is done well:**
- Thorough preprocessing that strips annotations, footnote references, and footnote definitions
- Proper use of `AttributedString(markdown:)` with `.full` syntax interpretation
- Block-level styling with proper paragraph spacing
- Fallback to plain text if markdown parsing fails
- Good visual hierarchy with different heading sizes

**Issues found:**

1. **(Important)** Line 189: `try! NSAttributedString(attributed, including: \.appKit)` -- this force-try will crash the extension if the conversion fails. In a QuickLook extension, a crash means no preview and potentially a system-level error log. This should be a `try` with error handling or at minimum a `try?` with a fallback:
```swift
if let result = try? NSAttributedString(attributed, including: \.appKit) {
    return result
} else {
    // Fallback to plain text
    return NSAttributedString(string: markdown, attributes: [...])
}
```

2. **(Suggestion)** The annotation regex `<!--\\s*::\\w+::\\s*[\\s\\S]*?-->` uses `[\\s\\S]*?` which matches across lines. With `NSRegularExpression` (which defaults to single-line mode), the `\\s\\S` pattern is the correct way to match across lines. This is fine.

3. **(Suggestion)** The separator line uses Unicode box-drawing character U+2500 repeated 20 times. This is a fine visual choice, but consider using `String(repeating: "\u{2500}", count: 20)` for clarity.

---

## 8. Package Type (com.apple.package) Considerations

The UTType declaration in `project.yml` (lines 102-109):
```yaml
UTExportedTypeDeclarations:
  - UTTypeIdentifier: com.kerim.final-final.document
    UTTypeConformsTo:
      - com.apple.package
      - public.composite-content
    UTTypeTagSpecification:
      public.filename-extension:
        - ff
```

This is correctly configured. The type conforms to `com.apple.package` which tells Finder to treat `.ff` directories as opaque bundles.

**Key consideration:** The UTType declaration lives in the **main app's** Info.plist, not in the QuickLook extension's. This is correct -- the app owns and exports the type, and the extension references it via `QLSupportedContentTypes`. However, the type declaration must be registered with the system before the extension can match against it. This happens when:
1. The app is first launched, or
2. The app is installed to `/Applications` (LaunchServices scans it)

If the app has never been launched after a clean install, the UTType might not be registered yet, and the QuickLook extension would never be invoked because the system does not know what `com.kerim.final-final.document` is. This could be a contributing factor if previews are not working even after all other fixes.

**Recommendation:** After a clean install, explicitly launch the app once before testing QuickLook previews. Alternatively, run `lsregister` to force-register:
```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/FINAL|FINAL.app"
```

**Severity: Important (could be a hidden blocker)**

---

## 9. Build Script Review (scripts/build.sh)

**What is done well:**
- Inside-out signing is correct (lines 96-105)
- Uses `ditto` for zip creation (preserves macOS metadata)
- Version auto-increment with project.yml and package.json sync
- Clear step-by-step output with colored messages

**Issues found:**

1. **(Important)** Line 105: After signing the main app, the outer codesign may re-seal the extension. While `--force` on the main app should not alter the inner extension's signature, it IS best practice to verify after signing:
```bash
codesign --verify --deep --strict "/Applications/$APP_NAME.app"
```
Add this verification step after signing.

2. **(Suggestion)** The build script does not reset QuickLook caches. Consider adding:
```bash
qlmanage -r 2>/dev/null
qlmanage -r cache 2>/dev/null
```
after installation, so the user does not have to remember to do it manually.

3. **(Suggestion)** The script signs the app in `/Applications/` after copying. This means the build artifact in `build/Build/Products/Debug/` is NOT properly signed. The zip created on line 125 uses the `/Applications/` copy (which IS signed), so this is fine for distribution. But it is worth noting that the DerivedData copy will have xcodebuild's default signing, which may differ.

---

## Summary of Issues by Priority

### Critical (must fix before testing)
1. Add `url.startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` in `PreviewViewController.preparePreviewOfFile` as a defensive measure for package directory access
2. Clean up all 5 duplicate registrations before rebuilding
3. Do NOT add `com.apple.security.files.user-selected.read-only` blindly -- test without it first after the codesign fix, then add security-scoped resource access if needed

### Important (should fix)
4. Add `os_log` diagnostic logging (as proposed -- agreed)
5. Handle `try!` crash risk in `MarkdownRenderer.parseAndStyle` (line 189)
6. Launch the app once after clean install (or run `lsregister`) to ensure UTType registration
7. Add `codesign --verify --deep --strict` after signing in build script
8. Document the intentional `handler(nil)` in the error path of `preparePreviewOfFile`

### Suggestions (nice to have)
9. Filter bibliography blocks from SQL query (as proposed -- agreed)
10. Consolidate Info.plist sources (static plist vs. xcodegen properties)
11. Add `qlmanage -r` to build script after installation
12. Consider a `LIMIT` on the block query for large documents
13. Replace `try!` patterns with safe alternatives in MarkdownRenderer

---

## Recommended Implementation Order

1. Add `os_log` to PreviewViewController (visibility into what is happening)
2. Add `startAccessingSecurityScopedResource()` to PreviewViewController
3. Fix `try!` in MarkdownRenderer line 189
4. Clean up stale registrations (delete DerivedData + old /Applications copy)
5. Full rebuild + clean install via build.sh
6. Launch app once to register UTType
7. Reset QuickLook: `qlmanage -r && qlmanage -r cache`
8. Test with `qlmanage -p` while monitoring Console.app
9. If still failing, check logs for sandbox violations and adjust entitlements accordingly
10. Add bibliography filter to SQL query (last, as it is cosmetic)
