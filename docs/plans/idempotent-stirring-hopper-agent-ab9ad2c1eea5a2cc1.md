# Code Review: Debug Editor Switch Corruption + Fix Image Centering

**Plan reviewed:** `docs/plans/idempotent-stirring-hopper.md`
**Reviewer:** Code Review Agent
**Date:** 2026-02-28

---

## Summary

The plan proposes two changes: (1) adding diagnostic print() logging across 3 Swift files to trace the WYSIWYG-to-Source and Source-to-WYSIWYG editor switch flow, and (2) a CSS one-liner for image centering. Both are reasonable, but the logging plan has significant gaps that would leave the most likely corruption sources unobserved.

---

## 1. Debug Logging Assessment

### What the plan covers well

- Tracing the WYSIWYG-to-Source path in `ViewNotificationModifiers.swift` (lines 43-106): block fetch, offset computation, anchor injection, bibliography marker. This is thorough.
- Logging `flushContentToDatabase()` in `EditorViewState+Zoom.swift` (the parse step). Good -- this will show whether BlockParser produces the expected block count and fragments.
- Logging `configureForCurrentProject()` in `ContentView+ProjectLifecycle.swift` at the load/assemble step. Useful as a baseline.

### Critical gaps (must add)

**Gap 1: The Source-to-WYSIWYG path is under-instrumented.**

The plan only logs 3 points in the Source-to-WYSIWYG direction (lines 107-128 in `ViewNotificationModifiers.swift`):
- `sourceContent` length at entry
- After `extractSectionAnchors`
- After setting `content`

But it misses the `flushContentToDatabase()` call at line 110 -- the plan only instruments flush in `EditorViewState+Zoom.swift` generically, not its input/output specifically when called from the source-to-WYSIWYG path. Since the context description says "content is already corrupted on first load", this direction matters as much as the other.

**Recommendation:** Add a log line immediately before and after `editorState.flushContentToDatabase()` at line 110 of the Source-to-WYSIWYG block showing `editorState.sourceContent.count` and `editorState.content.count`, so the reviewer can confirm what content was flushed.

**Gap 2: No logging in `saveAndNotify()` (the pre-switch content sync).**

The actual editor switch flow is two-phase:
1. User presses Cmd+/ which triggers `.didSaveCursorPosition` notification
2. `saveAndNotify()` in `MilkdownCoordinator+Content.swift` (line 270) first fetches content from the WebView via `getContent()`, writes it to the binding, THEN posts `.didSaveCursorPosition`
3. `.didSaveCursorPosition` handler (line 131 in `ViewNotificationModifiers.swift`) posts `.toggleEditorMode`
4. `.toggleEditorMode` handler (line 38) does the actual switch

This means the content in `editorState.content` at the time the switch starts was set by `saveAndNotify()`. If the WebView returns corrupted content from `getContent()`, all the downstream logging will only show already-corrupted data. **This is the most likely corruption source and the plan does not instrument it at all.**

**Recommendation:** Add logging in `saveAndNotify()` at `MilkdownCoordinator+Content.swift` line ~299:
```swift
print("[SAVE+NOTIFY] getContent returned length=\(content.count), preview=\(String(content.prefix(200)))")
```

This would capture the content as it comes back from JS before any Swift processing.

**Gap 3: No logging of the CodeMirror coordinator's `saveAndNotify()`.**

When switching FROM source TO WYSIWYG, the CodeMirror coordinator's equivalent of `saveAndNotify()` runs first. The plan should also add logging there (`CodeMirrorCoordinator+Handlers.swift`), since the `sourceContent` binding is set from the JS `getContent()` return value in that path.

**Gap 4: No logging for `BlockParser.assembleMarkdown()`.**

The plan instruments `BlockParser.parse()` output but not `BlockParser.assembleMarkdown()`. The context says "heading merged with body" and "1 block ID" -- this could mean `assembleMarkdown` receives only 1 block and joins it correctly (the parse was wrong), or it receives multiple blocks but joins them incorrectly. Without logging at `assembleMarkdown`, we cannot distinguish these cases.

**Recommendation:** Add a temporary log at `BlockParser.assembleMarkdown()` showing input block count and output length:
```swift
print("[ASSEMBLE] \(blocks.count) blocks -> \(result.count) chars")
```

**Gap 5: No logging for the `onChange(of: editorState.content)` guard in `withContentObservers`.**

Line 272 in `ViewNotificationModifiers.swift` has `guard editorState.contentState == .idle else { return }`. During a switch, contentState is `.editorTransition`, so this guard prevents side effects. But if `contentState` returns to `.idle` prematurely (e.g., due to the 1500ms Task.sleep racing), the `onChange` observer could fire with intermediate content, triggering block re-parse and overwriting the database. This race condition should be logged.

**Recommendation:** Add a log at the guard:
```swift
if editorState.contentState != .idle {
    print("[CONTENT-OBSERVER] Skipped: contentState=\(editorState.contentState)")
}
```

### Important gaps (should add)

**Gap 6: The empty `catch` at line 92 of `ViewNotificationModifiers.swift`.**

The WYSIWYG-to-Source path has `} catch { }` (line 92) which silently swallows errors from `fetchBlocks`. If the DB query fails, all section offsets will be empty and anchor injection will silently do nothing. This should at minimum log the error:
```swift
} catch {
    print("[SWITCH->CM] fetchBlocks error: \(error)")
}
```

**Gap 7: No logging for `injectSectionAnchors` or `extractSectionAnchors` input validation.**

These functions in `SectionSyncService+Anchors.swift` perform offset-based string insertion. If `section.startOffset` exceeds the markdown length, the `min()` clamp at line 46 silently adjusts it, which could inject anchors at wrong positions. Adding a warning when clamping occurs would help:
```swift
if section.startOffset > result.count {
    print("[ANCHORS] WARNING: offset \(section.startOffset) exceeds content length \(result.count)")
}
```

### Suggestions (nice to have)

**S1: Tag all debug logs for easy filtering.**

The plan uses tags like `[SWITCH->CM]`, `[SWITCH->MW]`, `[FLUSH]`, `[LOAD]`. This is good practice. Consider also adding a session/sequence counter so that concurrent or rapid switches can be distinguished in the logs.

**S2: Consider wrapping in `#if DEBUG` guards.**

The plan shows unconditional `print()` statements. The existing codebase uses `#if DEBUG` guards for some logging. For consistency and to avoid shipping debug noise, the new logging should also use `#if DEBUG`. However, for a temporary debugging session that will be removed, unconditional `print()` is acceptable.

**S3: Add content hash for quicker comparison.**

Instead of printing 200-character previews, consider also printing a hash of the full content (e.g., `content.hashValue` or a simple checksum). This makes it trivial to see when content actually changed between stages without comparing long strings.

---

## 2. CSS Fix Assessment

### The proposed change

```css
.figure-node img {
  display: block;
  max-width: 100%;
  height: auto;
  border-radius: 4px;
  margin: 0 auto;  /* Center images that have explicit width from resize */
}
```

### Verdict: Correct

The fix is technically correct. When `image-plugin.ts` sets `style.width = "Xpx"` on an `<img>` element (lines 178, 243, 353 of `image-plugin.ts`), the image gets an explicit pixel width that is narrower than its container. Without `margin: 0 auto`, a `display: block` element with an explicit width will be left-aligned by default. Adding `margin: 0 auto` centers it within the `.figure-node` parent.

### One consideration

The `.figure-node` parent has `display: block` and `max-width: 100%`, so it will fill the editor column. The `margin: 0 auto` on the `img` inside it will center the image within that full-width block. This is the standard pattern and should work correctly.

Images without explicit width have `max-width: 100%` (or `style.maxWidth = '100%'` set by the JS), which makes them fill the container -- in that case `margin: 0 auto` has no visible effect since the image is already full width. So the fix is non-breaking for non-resized images.

The `margin: 0 auto` will override any `margin` that might be set inline via JS, but looking at the image-plugin.ts code, only `width` and `maxWidth` are set inline -- no inline margins. So there is no conflict.

---

## 3. Threading and Performance

### No performance concerns

The `print()` statements are trivially cheap. Swift's `print()` is synchronous and writes to stdout. In a macOS app, this goes to the Xcode console with negligible overhead. The string interpolation (`.prefix(200)`, `.count`) is O(n) but the content is small (a few KB). No concerns here.

### Threading is correct

All the proposed logging sites are already on `@MainActor`:
- `withEditorNotifications` runs in SwiftUI's `.onReceive` (main thread)
- `flushContentToDatabase()` is in `EditorViewState` which is `@MainActor`
- `configureForCurrentProject()` is explicitly `@MainActor` in `ContentView+ProjectLifecycle.swift`

No threading issues.

---

## 4. Overall Recommendation

The plan is a reasonable start, but in its current form it **will likely miss the actual corruption point**. The most probable corruption source is the JS `getContent()` return value in `saveAndNotify()` (the pre-switch content sync), which the plan does not instrument at all. Without Gap 1, 2, and 3 being addressed, the logging will only show the downstream effects of corruption, not where it actually enters the Swift side.

**Priority order for additions:**
1. **(Critical)** Log `saveAndNotify()` in `MilkdownCoordinator+Content.swift` -- the JS `getContent()` return
2. **(Critical)** Log the CodeMirror equivalent of `saveAndNotify()` for Source-to-WYSIWYG path
3. **(Important)** Fix the silent `catch { }` at line 92 of `ViewNotificationModifiers.swift`
4. **(Important)** Log `BlockParser.assembleMarkdown()` input/output
5. **(Important)** Log the `contentState` guard in the `onChange(of: editorState.content)` observer
6. **(Suggestion)** Add `#if DEBUG` guards for consistency
7. **(Suggestion)** Add content hash values alongside length for quick comparison

The CSS fix is correct and ready to apply as-is.
