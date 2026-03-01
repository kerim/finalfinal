# Review: Fix PDF Export Failure with WebP/Non-PNG Images

## Overall Assessment

The plan is well-structured, correctly identifies the root cause, and proposes a reasonable solution that fits within the existing codebase. The single-file modification approach is appropriate -- `ExportService.swift` is the right place for this logic. Below are findings organized by severity.

---

## Critical Issues (Must Fix)

### 1. Regex does not match the actual image path format in export markdown

**The plan's regex**: `\(media/([^)]+)\)`

**The actual markdown output** from `Block.markdownForExport()` (line 347 of `Block.swift`):

```swift
var result = "![\(displayText)](\(src))"
```

Where `src` comes from `block.imageSrc`, which stores values like `media/photo.webp`.

The plan's regex `\(media/([^)]+)\)` will match `(media/photo.webp)` -- this looks correct on the surface. However, `markdownForExport()` can also append Pandoc attributes immediately after the closing paren:

```
![caption](media/photo.webp){fig-alt="description" width=400px}
```

The regex as written would work because it captures up to `)`, but the plan's step 4 says to "rewrite image paths in the markdown content" by replacing `media/name.webp` with `media/name.png`. This string replacement approach will correctly handle the attributes case since it replaces the path substring, not the whole markdown syntax.

**Verdict**: On closer inspection, this is actually fine. The regex extracts filenames, and the replacement operates on the path substring. No issue here -- I retract the "critical" label.

---

## Important Issues (Should Fix)

### 1. Duplicate filename collision: `photo.png` and `photo.webp` in the same project

The plan does not address what happens when `media/` contains both `photo.png` and `photo.webp`. After conversion, both would map to `media/photo.png` in the temp directory. The second copy/conversion would silently overwrite the first.

**Recommendation**: When a converted filename collides with an existing file in the temp `media/` directory, add a suffix (e.g., `photo-converted.png`). The `ImageImportService.uniqueFilename()` method (line 174 of `ImageImportService.swift`) already implements this pattern and could serve as a reference.

### 2. The `rewriteImagePaths` helper already exists but the plan does not reuse it

`ExportService.swift` already has a `rewriteImagePaths(in:from:to:)` method (line 774) used by markdown and TextBundle exports:

```swift
private func rewriteImagePaths(in content: String, from oldPrefix: String, to newPrefix: String) -> String {
    content.replacingOccurrences(of: "(\(oldPrefix)", with: "(\(newPrefix)")
}
```

This method does simple prefix replacement (`(media/` to `(newprefix/`). For the PDF fix, the plan needs per-file replacement (only changing the extension for converted files), so this helper is not directly usable. That said, the plan should explicitly note why it cannot reuse this existing method, to avoid confusion during implementation.

### 3. No temp directory created when all images are already compatible

The plan says "no temp dir created" when there are no images. But what about when there ARE images and all are PNG/JPG? The plan still creates a temp directory, copies all compatible images, and redirects `--resource-path`. This is unnecessary overhead.

**Recommendation**: Add a fast-path check. After scanning the markdown, if all referenced images have xelatex-compatible extensions, skip the entire `prepareImagesForPDF` process and leave `--resource-path` pointing at the project URL. Only create the temp directory when at least one image needs conversion.

### 4. NSImage is not guaranteed to handle all listed formats identically

The plan states "NSImage natively reads WebP, HEIC, TIFF, GIF, SVG, and BMP." This is true on macOS 11+, but SVG rendering through NSImage rasterizes at the image's intrinsic size, which for SVGs with no explicit dimensions may produce a very small image (e.g., 100x100 pixels). For PDF output where print quality matters, this could produce poor results.

**Recommendation**: For SVG specifically, consider using a higher DPI or explicit target size during rasterization. Alternatively, note this as a known limitation in the plan and consider adding a warning when SVG images are converted (e.g., "SVG images are rasterized for PDF export and may not appear at full resolution").

### 5. `import AppKit` may cause actor isolation warnings

The plan adds `import AppKit` to `ExportService.swift`, which is an `actor`. `NSImage` and `NSBitmapImageRep` are AppKit classes. While `NSImage(contentsOf:)` and the TIFF/PNG conversion chain do not require the main thread (the plan correctly notes this), future Swift concurrency changes may flag these as potential isolation issues.

**Recommendation**: Document in the code comment that `NSImage(contentsOf:)` is safe to call off-main-thread, and that only `NSImage.init(named:)` and display-related methods require `@MainActor`.

---

## Suggestions (Nice to Have)

### 1. Consider a Pandoc Lua filter as an alternative

Pandoc supports Lua filters that can modify the AST before rendering. A Lua filter could intercept image nodes and convert files on the fly. This would keep the conversion logic closer to the Pandoc pipeline.

However, after reviewing the [Pandoc WebP issue (#5267)](https://github.com/jgm/pandoc/issues/5267), the community consensus is that LaTeX simply does not support WebP and pre-conversion is the standard workaround. A Lua filter would still need to shell out to a conversion tool, making it more complex than the NSImage approach. The plan's approach is the right one.

### 2. Convert at import time instead of export time

An alternative approach: convert unsupported images to PNG when they are first imported via `ImageImportService`. This would avoid the per-export conversion overhead entirely.

**Trade-offs**:
- Pro: Simpler export path, no temp directory management, conversion happens once
- Pro: All downstream consumers (Quick Look preview, other export formats) benefit
- Con: Lossy -- users lose the original WebP/HEIC file (unless both are stored)
- Con: WebP is often significantly smaller than PNG; storing as PNG increases project size
- Con: Requires migrating existing projects that already contain WebP images
- Con: Changes the import contract (users expect their image format to be preserved)

**Verdict**: The plan's export-time conversion approach is better for this use case. It preserves original files and only converts when needed for a format that requires it.

### 3. Add a progress indicator for large image sets

For projects with many images (10+), the conversion step could add noticeable delay to PDF export. The `ExportViewModel` already has `progressMessage` (line 88 of `ExportViewModel.swift`). Consider updating it during conversion (e.g., "Converting images for PDF...").

This would require passing a progress callback into `prepareImagesForPDF`, which adds complexity. Likely not worth it for v1 but worth noting.

### 4. Consider symlinks instead of copies for compatible images

The plan mentions "(or symlink)" for compatible images but does not commit to one approach. Symlinks would be faster and use no extra disk space. The only risk is if Pandoc or xelatex resolves symlinks differently, but in practice they follow symlinks fine on macOS.

**Recommendation**: Use symlinks for compatible images, file copies for converted images. Add a comment explaining why.

---

## Completeness Check

### Files that need modification
- `final final/Services/ExportService.swift` -- Yes, this is the only file that needs changes. The plan is correct.

### Files that do NOT need modification
- `ExportCommands.swift` -- No changes needed. The export flow already passes `projectURL` through.
- `ExportViewModel.swift` -- No changes needed. Warnings from `ExportResult` are already displayed in `showExportSuccessAlert`.
- `FileCommands.swift` -- No changes needed. Menu structure is unchanged.
- `Block.swift` -- No changes needed. Image markdown generation is unchanged.
- `ImageImportService.swift` -- No changes needed. Import behavior is unchanged.

### Error handling coverage
The existing `ExportError` enum and the `ExportViewModel.showExportErrorAlert` method will handle failures from the conversion step. If `NSImage(contentsOf:)` fails for a particular image, the plan adds it to the warnings list and skips it. This is appropriate -- a missing/unconvertible image should not block the entire export.

### User-facing messages
Conversion warnings will appear in the "Export Complete with Warnings" dialog via `ExportViewModel.showExportSuccessAlert`. No new UI code is needed.

---

## Verification Section Assessment

The plan's 5 verification items are necessary but not sufficient. Additional test cases to add:

6. Export a project containing an SVG image as PDF -- verify the rasterized image appears at reasonable quality
7. Export a project where `media/` contains both `photo.png` and `photo.webp` -- verify no overwrite collision
8. Export a project with HEIC images (common from iPhone screenshots) -- verify conversion works
9. Export a project with a very large image (>10 MB WebP) -- verify conversion does not hang or crash
10. Export a project with images that have Pandoc attributes (captions, width) -- verify attributes are preserved after path rewriting

---

## Summary

The plan is sound. The approach of converting at export time in a temp directory is the correct architectural choice. The single-file modification scope is accurate. The main items to address before implementation:

1. **Important**: Handle duplicate filename collisions (`photo.png` + `photo.webp`)
2. **Important**: Add a fast-path to skip temp directory creation when no conversion is needed
3. **Important**: Note SVG rasterization quality limitations
4. **Suggestion**: Use symlinks for compatible images
5. **Suggestion**: Expand verification test cases
