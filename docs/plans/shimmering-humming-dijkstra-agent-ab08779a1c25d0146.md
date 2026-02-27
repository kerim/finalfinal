# Review: Revised Plan for Content Flush Before Project Switch/Close

## Review Status: APPROVED WITH NOTES

The revised plan is sound and addresses the previous round's concerns well. Below is a detailed validation of each question raised, plus additional observations.

---

## Question 1: Is removal of blockSyncService.flushNow() correct?

**Verdict: YES, correct.**

`BlockSyncService` operates via a poll-based incremental sync: it calls `window.FinalFinal.getBlockChanges()` every 2 seconds and applies deltas (updates, inserts, deletes) using temp-to-permanent ID mapping. Meanwhile, `flushContentToDatabase()` in `EditorViewState+Zoom.swift` (line 348) does a *full reparse* of `editorState.content` via `BlockParser.parse()` and then calls `db.replaceBlocks()` (or `db.replaceBlocksInRange()` when zoomed). This generates entirely new block UUIDs.

If `blockSyncService.flushNow()` were called *after* `flushContentToDatabase()`, it would try to apply incremental changes referencing old block IDs that no longer exist in the database. This would either fail silently or corrupt data. The plan's decision to omit it is correct.

However, there is one subtlety worth noting: `flushContentToDatabase()` uses `editorState.content` which may be stale if the JS editor has unsaved changes within its internal debounce window. The plan addresses this by fetching fresh content from the WebView first in `flushAllPendingContent()` -- which is the right approach.

---

## Question 2: Race condition during await calls in flushAllPendingContent()?

**Verdict: LOW RISK, but worth mitigating.**

The plan places `await flushAllPendingContent()` as the FIRST line of `handleProjectOpened()`, *before* `stopPolling()` and `cancelPendingSync()`. During the `await fetchContentFromWebView()` call, the following could fire:

- **Content push from JS** (`handleContentPush`): Could update `editorState.content` concurrently. Since everything is `@MainActor`, calls are serialized, but a push arriving between `fetchContentFromWebView()` returning and `editorState.content = freshContent` being set would be immediately overwritten by the fresh content. This is actually *fine* -- the fresh content is newer.

- **BlockSyncService poll timer** (2s interval): Could fire and apply incremental changes to DB. Then `flushContentToDatabase()` would overwrite them with the full reparse. This is safe because `flushContentToDatabase()` does a full `replaceBlocks()`.

- **SectionSyncService debounce** (500ms): Could fire its debounced `syncContent()`. Then `syncNow()` would fire again. The section reconciler is idempotent, so double-syncing is harmless.

**Recommendation:** The current ordering (flush BEFORE stopPolling) is actually safer than the alternative. If you stopped polling first and then flushed, you might miss the very last content change that was being polled. The plan's ordering is correct.

One edge case: the `contentState` check in `handleContentPush` (`guard self.contentState == .idle`). If `flushContentToDatabase()` does not change `contentState` (and looking at the code, it does not -- it only changes it during zoom transitions), then a push could still arrive. But since `flushAllPendingContent()` just fetched the freshest content from JS, any push during the flush window would contain the same or older content. No real risk.

---

## Question 3: Is the fetchContentFromWebView() continuation pattern safe?

**Verdict: YES, safe.**

The plan uses `withCheckedContinuation` to bridge WKWebView's callback-based `evaluateJavaScript` API. WKWebView completion handlers run on the main thread. The calling code is `@MainActor`. Resuming a `CheckedContinuation` from the main thread when the caller is also `@MainActor` is safe -- this is the standard pattern used throughout this codebase already.

Evidence: `BlockSyncService` uses the identical pattern at lines 117-121, 158-160, and 223-230. The codebase has no issues with this approach.

One important detail: the plan should ensure the continuation is always resumed, even if `evaluateJavaScript` returns an error. The completion handler receives `(Any?, Error?)` -- if there's an error, the handler should still resume the continuation (returning nil). This is a standard defensive practice. The plan description mentions "Returns nil if WebView unavailable" which suggests this is handled, but the implementation should explicitly handle the error path.

---

## Question 4: Is synchronous-only flush in performProjectClose() acceptable?

**Verdict: ACCEPTABLE GAP, with one concern.**

`performProjectClose()` is a synchronous method. The plan adds `editorState.flushContentToDatabase()` as the first line, which persists `editorState.content` to the block database. This does NOT:

1. Fetch fresh content from WebView (could miss edits within JS's internal debounce)
2. Sync sections to the section table
3. Sync annotation positions

Analysis of each gap:

**Gap 1 (fresh content):** This is the most significant. If the user made a change less than ~50ms before closing, it might not have been pushed to `editorState.content` yet. However, the JS push-based messaging (`handleContentPush`) fires on every Milkdown doc change, and the grace period is only 200ms. In practice, by the time a user clicks "Close Project," the content push has almost certainly already fired. Risk is very low.

**Gap 2 (sections):** Section sync is a derived view of the content. Sections are re-parsed from blocks on the next project open. Not persisting them here means the section table might be slightly stale, but it will be rebuilt from blocks on next load. No data loss.

**Gap 3 (annotations):** Similar to sections -- annotation positions are derived from content. They'll be re-synced on next open. Minor staleness, no data loss.

**The real concern:** `performProjectClose()` currently fires `autoBackupService.projectWillClose()` inside a `Task { }` (fire-and-forget async). The plan adds `flushContentToDatabase()` BEFORE this, which is correct -- the backup will get the freshest blocks. However, the backup task itself may not complete before the method returns and `resetForProjectSwitch()` clears all state. This is a pre-existing issue, not introduced by the plan.

**Recommendation:** Consider making `performProjectClose()` async in a future iteration, so it can call the full `flushAllPendingContent()`. For now, the synchronous flush is a reasonable pragmatic choice.

---

## Question 5: Should the orphaned Task in applicationWillTerminate be removed?

**Verdict: SHOULD BE CLEANED UP, but not blocking.**

The current code at `AppDelegate.swift` lines 228-233:

```swift
if let state = editorState, state.zoomedSectionId != nil {
    Task { @MainActor in
        await state.zoomOut()
    }
}
```

This `Task` is fire-and-forget in `applicationWillTerminate`. The method returns immediately, and the app process exits. The Task never gets to run its body. This is dead code.

The plan adds `editorState?.flushContentToDatabase()` in `applicationWillTerminate`, which IS synchronous and WILL execute. The dead `zoomOut()` Task should be removed for clarity, but leaving it does no harm -- it just creates false expectations for future readers.

**Recommendation:** Remove the dead Task in a cleanup pass, or add a comment explaining it cannot actually run. Not a blocker for this fix.

---

## Question 6: Additional callers of handleProjectOpened() / performProjectClose()

**Findings:**

**handleProjectOpened() in ContentView+ProjectLifecycle.swift** is called from:
1. `ContentView.swift` line 115: `onOpened: { await handleProjectOpened() }` -- the primary call site
2. `ContentView+ProjectLifecycle.swift` line 300: `await self.handleProjectOpened()` -- from `handleCreateFromGettingStarted()`

**performProjectClose()** is called from:
1. `ContentView+ProjectLifecycle.swift` line 251: inside `handleProjectClosed()` -- the primary call site

**FinalFinalApp.swift** lines 64-67 has its OWN `handleProjectOpened()` which is a DIFFERENT method (it just updates `appViewState`). This is NOT the ContentView method and does NOT need the flush.

All call sites are accounted for. The `handleCreateFromGettingStarted()` path (call site 2 for `handleProjectOpened`) is particularly important -- it already calls `handleProjectOpened()` which will get the flush. No additional files need modification.

---

## Additional Observations

### A. Zoom state handling in flushAllPendingContent()

The plan's `flushAllPendingContent()` calls `flushContentToDatabase()` which already handles zoomed state correctly -- it checks `zoomedBlockRange` and uses `replaceBlocksInRange()` when zoomed (lines 377-384 in EditorViewState+Zoom.swift). No issue here.

### B. Content emptiness guard

The plan includes `guard !editorState.content.isEmpty else { return }` after fetching fresh content. This is important -- during the very first project load or if the WebView hasn't initialized yet, `content` could legitimately be empty. The guard prevents accidentally wiping the database with an empty reparse. Correct.

### C. The plan does not address the Getting Started project case

In `handleProjectClosed()`, if `isGettingStartedProject && isGettingStartedModified()`, the method shows an alert and returns WITHOUT calling `performProjectClose()`. The flush would happen later when the user chooses an action (either `handleCreateFromGettingStarted` or a second call to `performProjectClose`). The `handleCreateFromGettingStarted` path calls `handleProjectOpened` which includes the flush. The discard path calls `performProjectClose` which includes the synchronous flush. Both are covered.

### D. Thread safety of flushContentToDatabase()

`flushContentToDatabase()` accesses `content`, `projectDatabase`, `currentProjectId`, `blockReparseTask`, and `zoomedBlockRange` -- all properties on `@MainActor` `EditorViewState`. Since `flushAllPendingContent()` is called from `handleProjectOpened()` which is already `@MainActor` (ContentView extension), all accesses are safe.

---

## Summary

| Question | Verdict |
|----------|---------|
| 1. Remove blockSyncService.flushNow()? | Correct |
| 2. Race condition during await? | Low risk, current ordering is good |
| 3. CheckedContinuation safety? | Safe (ensure error path resumes) |
| 4. Sync-only flush in performProjectClose? | Acceptable gap |
| 5. Dead Task in applicationWillTerminate? | Should remove, not blocking |
| 6. Additional callers? | All accounted for |

**Overall: The revised plan is ready for implementation.** The two minor items to address during implementation are:

1. **Ensure `fetchContentFromWebView()` resumes the continuation on both success AND error paths** from `evaluateJavaScript`.
2. **Consider removing the dead `Task { await state.zoomOut() }` in applicationWillTerminate** while you're editing that file anyway.
