# Project Switch Bugs in Source Mode (CodeMirror)

**Date:** 2026-02-07
**Branch:** new-project-bug

## Overview

Two related bugs were found when switching between projects while in Source mode (CodeMirror). Both stem from the fact that CodeMirror and Milkdown bind to different content properties, and the project-switch code path only considered the WYSIWYG case.

---

## Bug 1: CodeMirror Showed Previous Project Content After Switch

### Symptoms
- Switch projects via File > Open Recent while in source mode
- CodeMirror briefly shows content from the **previous** project before the new content appears
- In some cases, the old content persists until a manual editor toggle (Cmd+/)

### Root Cause
On project switch, `handleProjectOpened()` was:
1. Destroying the WebView by setting `isEditorPreloadReady = false` (forcing re-creation)
2. Resetting `editorState.content = ""`
3. Clearing sections/annotations individually (missing some state)

The WebView destruction and re-creation caused a full reload cycle. During this time, stale content could flash because:
- The old WebView was still rendering while being torn down
- The new WebView loaded with empty content, then received the real content — but if `sourceContent` wasn't populated, it stayed blank (see Bug 2)

### Fix
Instead of destroying and re-creating the WebView on every project switch:

1. **Keep the WebView alive** — removed `isEditorPreloadReady = false` from `handleProjectOpened()`
2. **Added `resetForProjectSwitch()` to JS side** — clears undo history, CAYW state, search state, block IDs, and pending slash command state without destroying the editor
3. **Added `resetForProjectSwitch()` to `EditorViewState`** — centralized all state reset (content, sourceContent, sections, annotations, zoom, stats, goals) in one method instead of ad-hoc property clearing
4. **Added `isResettingContent` guard in `updateNSView`** — both MilkdownEditor and CodeMirrorEditor now skip content pushes while `isResettingContent = true`, preventing empty content from being pushed during reset
5. **Added CodeMirror preloading** — `EditorPreloader` now preloads both Milkdown and CodeMirror WebViews, so CodeMirror gets the same instant startup as Milkdown
6. **Added `BlockSyncService.reconfigure()`** — allows repointing the database/projectId on project switch without recreating the service

### Files Changed
- `ContentView.swift` — `handleProjectOpened()` rewritten to keep WebView alive, call JS reset, use centralized state reset
- `EditorViewState.swift` — added `resetForProjectSwitch()` method
- `EditorPreloader.swift` — added CodeMirror preloading alongside Milkdown
- `CodeMirrorEditor.swift` — added preloaded WebView support in `makeNSView()`, `isResettingContent` guard in `updateNSView`, `handlePreloadedView()`
- `MilkdownEditor.swift` — added `isResettingContent` guard in `updateNSView`, trace logging
- `BlockSyncService.swift` — added `reconfigure()` method
- `web/codemirror/src/main.ts` — added `resetForProjectSwitch()`, extracted extensions to module level for EditorState recreation
- `web/milkdown/src/main.ts` — added `resetForProjectSwitch()` with ProseMirror state reset (clears undo history)

---

## Bug 2: Blank Screen for ~2 Seconds After Project Switch in Source Mode

### Symptoms
- Switch projects while in source mode
- Editor shows blank/empty for ~2 seconds, then content appears
- WYSIWYG mode works fine (content appears immediately)
- Cold start in source mode also works fine

### Root Cause
A binding mismatch between `configureForCurrentProject()` and CodeMirrorEditor:

1. `configureForCurrentProject()` sets `editorState.content` (the WYSIWYG property)
2. CodeMirrorEditor binds to `editorState.sourceContent` (a different property that includes section anchors and bibliography markers)
3. `sourceContent` is never populated during `configureForCurrentProject()`
4. `sourceContent` stays `""` until `rebuildDocumentContent()` fires ~2 seconds later (triggered by bibliography sync)

**Why cold start works:** The 2-second preload wait gives `rebuildDocumentContent()` time to run before the editor renders.

**Why WYSIWYG works:** MilkdownEditor binds to `editorState.content` directly.

**Trace evidence:**
```
[TRACE] +1.8ms markdown assembled, length=12862     <- content set correctly
[CM.updateNSView] contentLen=0 lastPushedLen=0       <- editor sees 0 (sourceContent is empty)
... 2 seconds later ...
[rebuildDocumentContent] Called. contentState=bibliographyUpdate  <- finally populates sourceContent
[CM.updateNSView] contentLen=13194 wouldPush=true    <- content appears
```

### Fix
Added `updateSourceContentIfNeeded()` call after every place `editorState.content` is set in `configureForCurrentProject()`:

```swift
editorState.content = BlockParser.assembleMarkdown(from: existingBlocks)
updateSourceContentIfNeeded()  // <-- populates sourceContent if in source mode
```

This existing function (line 739) checks `editorState.editorMode == .source` and populates `sourceContent` from `content` with anchor/bibliography marker injection. With empty sections (not yet delivered from observation), both `injectSectionAnchors` and `injectBibliographyMarker` return the markdown unchanged. So `sourceContent` gets set to `content` immediately.

When sections arrive later via ValueObservation, `rebuildDocumentContent` re-injects proper anchors seamlessly.

Three single-line additions in `ContentView.swift`:
1. After block-based content assembly
2. After legacy content loading
3. After empty content fallback

### Files Changed
- `ContentView.swift` — three `updateSourceContentIfNeeded()` calls in `configureForCurrentProject()`

---

## Lesson Learned

When a view model has mode-specific content properties (`content` for WYSIWYG, `sourceContent` for source), **every code path that sets `content` must also consider `sourceContent`**. The `updateSourceContentIfNeeded()` helper exists for exactly this purpose — use it whenever `content` is assigned outside of `rebuildDocumentContent()`.
