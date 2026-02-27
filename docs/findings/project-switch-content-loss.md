# Project Switch Content Loss (Links + Text Lost)

**Date:** 2026-02-28
**Severity:** Critical (silent data loss)
**Status:** Fixed

## Symptom

Links added via Cmd+K and plain text typed shortly before switching projects were silently lost. Switching back to the original project showed the content as it was before the edits.

## Root Cause

`handleProjectOpened()` and `performProjectClose()` cancelled all sync services without flushing pending content to the database first. `BlockSyncService` polls JS every 2 seconds to persist markdown content. When `stopPolling()` was called and `resetForProjectSwitch()` destroyed the JS-side block change queue, any edits accumulated since the last poll were silently discarded.

### Timeline of a lost edit

```
T=0ms    User adds link via Cmd+K -> ProseMirror transaction
T=50ms   JS debounce fires -> contentChanged message -> editorState.content updated
T=51ms   BlockSyncService has recorded change in JS-side queue, awaiting next 2s poll
T=200ms  User clicks to switch project -> handleProjectOpened() called
T=201ms  blockSyncService.stopPolling() -> kills 2s timer
T=202ms  JS resetForProjectSwitch() -> destroyBlockSyncState() wipes JS change queue
T=203ms  Content never written to database -> DATA LOST
```

### Why `onContentChange` didn't help

`onContentChange` is a no-op. Content flows through the SwiftUI binding (`editorState.content`), not callbacks. `SectionSyncService` handles section metadata, not content persistence. Only `BlockSyncService` writes blocks to DB.

## Fix

Added content flushing at three lifecycle boundaries:

### 1. `handleProjectOpened()` -- async flush before switch

Stop block polling first (prevents poll timer from firing during async suspension points), then flush all pending content to the OLD project's database before switching.

- `fetchContentFromWebView()` -- fetches latest content directly from WebView JS with a 2s timeout, bypassing the 50ms JS debounce
- `flushAllPendingContent()` -- updates `editorState.content` from WebView, calls `flushContentToDatabase()` (full block re-parse + write), flushes section metadata via `syncNow()`, flushes annotation positions

### 2. `performProjectClose()` -- synchronous flush

Added `editorState.flushContentToDatabase()` at the top of `performProjectClose()`. By button-click time the JS 50ms debounce has already fired, so `editorState.content` is current.

### 3. `applicationWillTerminate()` -- synchronous flush on quit

Replaced a dead `Task { await state.zoomOut() }` (fire-and-forget that never completes before process exit) with synchronous `editorState?.flushContentToDatabase()`. Handles both zoomed (range replace) and non-zoomed (full replace) cases.

## Key Design Decision

`flushContentToDatabase()` replaces all blocks with new UUIDs via `replaceBlocks()`. Calling `blockSyncService.flushNow()` afterward would read JS-side incremental changes referencing old block IDs, causing conflicts. `flushContentToDatabase()` alone is sufficient -- it persists the complete content atomically.

## Files Changed

| File | Change |
|------|--------|
| `final final/Views/ContentView+ProjectLifecycle.swift` | Added `fetchContentFromWebView()`, `flushAllPendingContent()`, integrated into `handleProjectOpened()` and `performProjectClose()` |
| `final final/App/AppDelegate.swift` | Replaced dead zoomOut Task with synchronous flush in `applicationWillTerminate` |

## Related Future Work

Three additional content-drop scenarios were identified during investigation but are separate issues:

1. **1500ms `.editorTransition` window** -- After switching CodeMirror to Milkdown, the `contentState == .idle` guard in `handleContentPush` silently drops all pushes for 1500ms
2. **200ms grace period** -- The `handleContentPush` guard drops pushes within 200ms of the last Swift-to-JS push if content differs. Fast paste-after-load could be lost
3. **No timeout on `.bibliographyUpdate` state** -- If the bibliography async task hangs, `contentState` stays non-idle indefinitely, silently dropping all subsequent edits
