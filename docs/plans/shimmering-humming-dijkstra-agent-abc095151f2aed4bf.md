# Code Review: Data Loss Bug Fix Plan

## Status: Review Complete

## Summary

This review validates the proposed fix for a data loss bug where links and plain text are silently discarded when switching between projects. After reading all key source files, I confirm the root cause diagnosis is largely correct but incomplete. The proposed fix is directionally sound but has several issues that must be addressed.

---

## 1. Root Cause Validation

### Diagnosis is PARTIALLY correct

The plan correctly identifies that `handleProjectOpened()` (line 183-185) and `performProjectClose()` (line 264-268) cancel sync services without flushing pending content first. However, the actual data loss mechanism is more nuanced than described.

### What the plan gets right

- `sectionSyncService.cancelPendingSync()` at line 185 does cancel a pending 500ms debounce task, which could discard unsaved section metadata changes.
- `blockSyncService.cancelPendingSync()` at line 184 clears pending ID confirmations, which could cause block ID mismatches.
- The ordering problem (cancel before flush) is real.

### What the plan misses or gets wrong

**Issue A: The primary content sync path is NOT the 500ms debounce.**

Looking at `MilkdownCoordinator+MessageHandlers.swift` line 648-668, the primary content sync uses a push-based model (`contentChanged` JS message handler via `handleContentPush`). This pushes content changes from JS to `contentBinding.wrappedValue` with a 50ms debounce on the JS side (main.ts lines 201-208). The `SectionSyncService` 500ms debounce is for section metadata reconciliation, not for the raw content itself.

The actual content pipeline is:
1. User edits in Milkdown
2. JS `dispatch` override fires after 50ms debounce (main.ts:202)
3. `contentChanged` postMessage sends markdown to Swift
4. `handleContentPush` updates `contentBinding.wrappedValue` (which is `editorState.content`)
5. `editorState.content` is the in-memory representation
6. BlockSyncService polls every 2s to sync block-level changes to DB
7. SectionSyncService debounces 500ms to sync section metadata to DB

So the real data loss vector is: **content exists in `editorState.content` (step 5) but the 2s BlockSyncService poll (step 6) has not yet written it to the database when the project switch fires.**

**Issue B: The JS 50ms debounce is also a vector.**

If the user makes a change and immediately switches projects (within 50ms), the JS `contentChanged` message may never fire. This means `editorState.content` on the Swift side could be stale. The proposed plan does not address fetching content directly from the WebView via `getContent()` before flushing.

**Issue C: `performProjectClose()` is synchronous but needs async operations.**

`performProjectClose()` at line 255 is a non-async function. It cannot `await` JS calls to `getContent()` from the WebView. The plan proposes calling `editorState.flushContentToDatabase()` (which is synchronous and reads from `editorState.content`), but this does not solve Issue B above -- the in-memory content might itself be stale by up to 50ms.

**Issue D: `applicationWillTerminate` has a bigger problem.**

At AppDelegate.swift line 218-233, `applicationWillTerminate` currently only handles zoom-out. It spawns a `Task` for `zoomOut()`, but `applicationWillTerminate` returns synchronously and the app terminates. The task may never complete. Adding `flushContentToDatabase()` here has the same problem -- if it is called inside a Task, the app may terminate before it runs; if called synchronously, it cannot fetch from the WebView.

---

## 2. Assessment of Proposed Fixes

### Fix 1: Add `flushNow()` to BlockSyncService

**Assessment: Important - Should Implement**

This is sound. Making `pollBlockChanges()` callable publicly allows forcing an immediate block sync. However, `pollBlockChanges()` is `async` because it calls `evaluateJavaScript` on the WebView, so `flushNow()` must also be `async`. This means it cannot be called from synchronous contexts like `performProjectClose()` or `applicationWillTerminate` without wrapping in a Task (which may not complete).

### Fix 2: Add `flushAllPendingContent()` to ContentView+ProjectLifecycle

**Assessment: Important - Should Implement, with modifications**

The proposed steps are:
1. Fetch content from WebView via `getContent()` -- CORRECT, this is necessary to capture the JS 50ms debounce window
2. Call `editorState.flushContentToDatabase()` -- CORRECT, this writes blocks to DB synchronously
3. Call `blockSyncService.flushNow()` -- REDUNDANT if step 2 already re-parsed and wrote all blocks
4. Call `sectionSyncService.syncNow()` and `annotationSyncService.syncNow()` -- CORRECT for metadata

The method must be `async` since step 1 requires `evaluateJavaScript`.

**Critical concern about step ordering:** The plan proposes calling `flushContentToDatabase()` THEN `blockSyncService.flushNow()`. But `flushContentToDatabase()` does a full re-parse and `replaceBlocks()`, while `blockSyncService.flushNow()` reads incremental changes from JS. If `flushContentToDatabase()` has already replaced all blocks, the incremental changes from JS are stale. **Step 3 should be removed entirely** -- it would either be a no-op or potentially write conflicting data.

### Fix 3: Call `flushAllPendingContent()` at top of `handleProjectOpened()`

**Assessment: Correct approach**

Since `handleProjectOpened()` is already `async`, calling an async flush method at the top is clean. However, the flush needs to operate on the PREVIOUS project's database, not the new one. The plan should explicitly note that the flush must happen before `documentManager` has switched to the new project.

### Fix 4: Call `editorState.flushContentToDatabase()` at top of `performProjectClose()`

**Assessment: Insufficient but acceptable as minimum viable fix**

`performProjectClose()` is not async. Calling `flushContentToDatabase()` (synchronous) will flush whatever is in `editorState.content` to the database. This covers most cases because the push-based content sync (50ms debounce) will have already updated `editorState.content` for any edit more than 50ms old.

The 50ms gap is a minor risk. To fully close it, `performProjectClose()` should be converted to async and fetch content from the WebView first. However, this involves changing the call site at `handleProjectClosed()` (line 244-252), which is called from a notification handler that may need to remain synchronous.

**Recommendation:** Accept the minor 50ms risk for `performProjectClose()` for now, and document it as a known limitation.

### Fix 5: Call `editorState.flushContentToDatabase()` in `applicationWillTerminate`

**Assessment: Problematic - Needs redesign**

`applicationWillTerminate` is synchronous and fires during app termination. The current code at line 228-233 already demonstrates this problem: it creates a Task to call `zoomOut()` but the task likely never completes.

`flushContentToDatabase()` is synchronous and reads from `editorState.content`, so it CAN be called directly in `applicationWillTerminate` without a Task. The concern is the same 50ms staleness issue as Fix 4.

**Better approach:** Use `applicationShouldTerminate(_:) -> NSApplication.TerminateReply` instead. This method can return `.terminateLater` to defer termination, perform async cleanup, then call `NSApp.reply(toApplicationShouldTerminate: true)`. This would allow fetching content from the WebView before flushing.

---

## 3. Race Conditions and Edge Cases

### Race Condition A: Concurrent flush and new project configuration

If `flushAllPendingContent()` is slow (WebView JS call can take 100-200ms) and the new project's database is configured while the flush is still writing to the OLD database, there is no race because the databases are different SQLite files. This is safe.

### Race Condition B: Stale content overwriting newer content

The plan asks about this. **This is a real risk with `blockSyncService.flushNow()`.** If the flush reads incremental JS changes that were already superseded by `flushContentToDatabase()`'s full re-parse, the incremental changes could partially overwrite the fresh data. **This is why step 3 of Fix 2 should be removed.**

### Race Condition C: WebView getContent() during project switch

When `handleProjectOpened()` fires, the WebView still contains the OLD project's content. Calling `getContent()` at this point is safe and returns the correct data. However, the plan also calls `resetForProjectSwitch()` on the JS side (line 197-199). If the reset runs before `getContent()`, the content is destroyed. **The flush MUST happen before the JS reset.**

### Edge Case: Zoomed content during project switch

If the user is zoomed into a section when switching projects, `editorState.content` contains only the zoomed subset, not the full document. `flushContentToDatabase()` correctly handles this case (line 377-415 in EditorViewState+Zoom.swift) by using `replaceBlocksInRange()` for zoomed content. This is safe.

### Edge Case: CodeMirror mode

The plan focuses on Milkdown but doesn't mention CodeMirror. `flushContentToDatabase()` works for both modes since it reads from `editorState.content` which is always current regardless of editor mode. However, CodeMirror has its own content sync path that may also have pending changes. This should be verified.

---

## 4. Corrected Implementation Plan

### Step 1: Add `flushNow()` to BlockSyncService

```swift
/// Force immediate sync of block changes from editor to database
func flushNow() async {
    await pollBlockChanges()
}
```

### Step 2: Add `flushAllPendingContent()` to ContentView+ProjectLifecycle

```swift
/// Flush all pending editor content to database before project switch/close.
/// Must be called BEFORE cancelling sync services or resetting state.
private func flushAllPendingContent() async {
    // 1. Fetch latest content from WebView (captures JS 50ms debounce window)
    let freshContent: String? = await withCheckedContinuation { continuation in
        findBarState.activeWebView?.evaluateJavaScript(
            "window.FinalFinal.getContent()"
        ) { result, _ in
            continuation.resume(returning: result as? String)
        }
    }

    // 2. Update editorState.content if we got fresh content
    if let freshContent, !freshContent.isEmpty {
        editorState.content = freshContent
    }

    // 3. Flush content to block database (synchronous, handles zoom state)
    editorState.flushContentToDatabase()

    // 4. Flush section metadata (cancels debounce and syncs immediately)
    await sectionSyncService.syncNow(editorState.content)

    // NOTE: Do NOT call blockSyncService.flushNow() here.
    // flushContentToDatabase() already wrote fresh blocks via full re-parse.
    // Incremental JS changes would conflict with the fresh data.
}
```

### Step 3: Modify `handleProjectOpened()`

Add flush call at line 180, BEFORE the cancel calls:

```swift
func handleProjectOpened() async {
    // Flush pending content from PREVIOUS project before switching
    await flushAllPendingContent()

    // Stop existing observation and services
    editorState.stopObserving()
    blockSyncService.stopPolling()
    blockSyncService.cancelPendingSync()
    sectionSyncService.cancelPendingSync()
    // ... rest unchanged
}
```

### Step 4: Modify `performProjectClose()`

Convert to async or add synchronous flush:

```swift
func performProjectClose() {
    // Synchronous flush of in-memory content to database
    // (covers all edits except the last ~50ms from JS debounce)
    editorState.flushContentToDatabase()

    // ... rest unchanged
}
```

### Step 5: Use `applicationShouldTerminate` instead of `applicationWillTerminate`

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Synchronous flush first (covers 99% of cases)
    editorState?.flushContentToDatabase()

    // If zoomed, merge content back (needs async)
    if let state = editorState, state.zoomedSectionId != nil {
        Task { @MainActor in
            await state.zoomOut()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    return .terminateNow
}
```

---

## 5. Issues Summary

### Critical (must fix)

1. **Fetch content from WebView before flushing** -- `editorState.content` can be up to 50ms stale. Call `getContent()` on the WebView first in the async path (`handleProjectOpened`).

2. **Remove `blockSyncService.flushNow()` from the flush sequence** -- It conflicts with `flushContentToDatabase()` which does a full re-parse and replace.

3. **Flush must happen BEFORE JS `resetForProjectSwitch()`** -- Line 197-199 of `handleProjectOpened()` clears the WebView content. If you call `getContent()` after this, you get empty string.

### Important (should fix)

4. **Use `applicationShouldTerminate` for graceful shutdown** -- `applicationWillTerminate` cannot reliably perform async cleanup. The `terminateLater` pattern is the standard macOS approach.

5. **Verify CodeMirror mode** -- The plan focuses on Milkdown but the app has a CodeMirror editor mode. Ensure CodeMirror's content sync path is also covered by the flush.

### Suggestions (nice to have)

6. **Consider converting `performProjectClose()` to async** -- This would allow fetching content from the WebView to close the 50ms staleness gap.

7. **Add a safety assertion** -- After the flush in `handleProjectOpened()`, verify that the database has non-empty content for the old project before proceeding. This catches regressions.

---

## 6. Files That Need Changes

| File | Change |
|------|--------|
| `/Users/niyaro/Documents/Code/ff-dev/saving-links/final final/Views/ContentView+ProjectLifecycle.swift` | Add `flushAllPendingContent()`, modify `handleProjectOpened()` and `performProjectClose()` |
| `/Users/niyaro/Documents/Code/ff-dev/saving-links/final final/Services/BlockSyncService.swift` | Add public `flushNow()` method |
| `/Users/niyaro/Documents/Code/ff-dev/saving-links/final final/App/AppDelegate.swift` | Add `applicationShouldTerminate`, modify `applicationWillTerminate` |

No changes needed to:
- `SectionSyncService.swift` -- already has `syncNow()` method (line 151-154)
- `EditorViewState+Zoom.swift` -- `flushContentToDatabase()` already exists and handles zoom
- Web/JS files -- no changes needed on the JS side
