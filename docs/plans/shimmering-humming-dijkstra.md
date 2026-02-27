# Fix: Content Loss on Project Switch (Links + Text Lost)

## Context

Users lose links (added via Cmd+K) and plain text when switching between projects. This is a critical data loss bug — the app must never silently discard user edits.

**Root cause:** `handleProjectOpened()` and `performProjectClose()` cancel all sync services without flushing pending content to the database first. `BlockSyncService` (2s poll) is the sole primary persistence path for markdown content. When `stopPolling()` is called and JS `resetForProjectSwitch()` destroys the block change queue, any unsaved edits are silently lost.

**Timeline of a lost edit:**
```
T=0ms    User adds link via Cmd+K → ProseMirror transaction
T=50ms   JS debounce fires → contentChanged message → editorState.content updated
T=51ms   BlockSyncService has recorded change in JS-side queue, awaiting next 2s poll
T=200ms  User clicks to switch project → handleProjectOpened() called
T=201ms  blockSyncService.stopPolling() → kills 2s timer
T=202ms  JS resetForProjectSwitch() → destroyBlockSyncState() wipes JS change queue
T=203ms  Content never written to database → DATA LOST
```

**Key insight from code review:** `onContentChange` is a no-op. Content flows through the SwiftUI binding (`editorState.content`), not callbacks. `SectionSyncService` is NOT involved in normal edit persistence — only `BlockSyncService` writes blocks to DB. But `flushContentToDatabase()` on `EditorViewState` does a full re-parse and block write synchronously, which is exactly what we need.

## Files to Modify

| File | Change |
|------|--------|
| `final final/Views/ContentView+ProjectLifecycle.swift` | Add `fetchContentFromWebView()`, `flushAllPendingContent()`, integrate into handlers |
| `final final/App/AppDelegate.swift` | Add content flush in `applicationWillTerminate` |

No changes needed to `BlockSyncService.swift` — the existing `flushContentToDatabase()` handles full block persistence without needing incremental block sync.

## Implementation

### Step 1: Add flush helpers to ContentView+ProjectLifecycle

**File:** `final final/Views/ContentView+ProjectLifecycle.swift`

Add two private methods:

```swift
/// Fetch latest content directly from WebView, bypassing JS 50ms debounce.
/// Returns nil if WebView is unavailable, JS call fails, or 2s timeout elapses.
/// Timeout prevents indefinite suspension if the WebView process is hung.
private func fetchContentFromWebView() async -> String? {
    guard let webView = findBarState.activeWebView else { return nil }
    return await withTaskGroup(of: String?.self) { group in
        group.addTask {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript("window.FinalFinal.getContent()") { result, error in
                    #if DEBUG
                    if let error { print("[ContentView] fetchContentFromWebView JS error: \(error)") }
                    #endif
                    continuation.resume(returning: result as? String)
                }
            }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil  // Timeout — fall through to editorState.content
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Flush all pending content to DB before project switch/close.
/// Must be called BEFORE resetForProjectSwitch() which clears editorState.content.
private func flushAllPendingContent() async {
    // 1. Fetch fresh content from WebView (catches edits within JS 50ms debounce)
    if let freshContent = await fetchContentFromWebView(), !freshContent.isEmpty {
        editorState.content = freshContent
    }
    guard !editorState.content.isEmpty else { return }

    // 2. Flush blocks to DB (synchronous — re-parses content into blocks and writes)
    //    This is the primary content persistence — same method used for zoom transitions
    //    and editor mode switches. Do NOT also call blockSyncService.flushNow() — that
    //    reads incremental changes referencing OLD block IDs that flushContentToDatabase()
    //    just replaced, causing ID conflicts.
    editorState.flushContentToDatabase()

    // 3. Flush section metadata (immediate write, bypasses 500ms debounce)
    await sectionSyncService.syncNow(editorState.content)

    // 4. Flush annotation positions
    await annotationSyncService.syncNow(editorState.content)

    #if DEBUG
    print("[ContentView] flushAllPendingContent completed")
    #endif
}
```

**Why no `blockSyncService.flushNow()`:** Code review identified that `flushContentToDatabase()` replaces all blocks with new UUIDs via `replaceBlocks()`. Calling `flushNow()` afterward would read JS-side incremental changes referencing the old IDs, causing conflicts and potential duplicate blocks. `flushContentToDatabase()` alone is sufficient — it persists the complete content.

### Step 2: Integrate into `handleProjectOpened()`

**File:** `final final/Views/ContentView+ProjectLifecycle.swift`

Stop block polling FIRST, then flush. The `await` suspension points in `flushAllPendingContent()` allow the cooperative executor to run other tasks — if the 2s poll timer is still active, it could fire during a suspension and write conflicting data to the DB.

```swift
func handleProjectOpened() async {
    // Stop block polling FIRST — prevents poll timer from firing during
    // the await suspension points in flushAllPendingContent() and writing
    // conflicting data to the database.
    blockSyncService.stopPolling()

    // Flush all pending content to OLD project's database before switching.
    await flushAllPendingContent()

    // Stop remaining services (existing code, unchanged)
    editorState.stopObserving()
    blockSyncService.cancelPendingSync()
    sectionSyncService.cancelPendingSync()
    annotationSyncService.cancelPendingSync()
    bibliographySyncService.reset()
    footnoteSyncService.reset()
    autoBackupService.reset()
    // ... rest unchanged from line 192 onward ...
}
```

**Ordering is critical:**
1. `blockSyncService.stopPolling()` — synchronous `Timer.invalidate()`, takes effect immediately
2. `await flushAllPendingContent()` — safe from poll interference now
3. Everything else — clears state, resets for new project

### Step 3: Integrate into `performProjectClose()`

**File:** `final final/Views/ContentView+ProjectLifecycle.swift`

Add synchronous flush at top. Keep `performProjectClose()` synchronous:

```swift
func performProjectClose() {
    // Flush pending content synchronously before closing.
    // editorState.content is current (JS 50ms debounce has fired by button click time).
    editorState.flushContentToDatabase()

    // Create auto-backup (existing code, unchanged)
    if !documentManager.isGettingStartedProject {
        Task { await autoBackupService.projectWillClose() }
    }
    // ... rest unchanged ...
}
```

### Step 4: Add flush to `applicationWillTerminate`

**File:** `final final/App/AppDelegate.swift`

Replace the existing zoom-out block with a synchronous flush:

```swift
func applicationWillTerminate(_ notification: Notification) {
    #if DEBUG
    print("[AppDelegate] Application terminating")
    #endif

    // Flush pending content to prevent data loss on quit.
    // Synchronous — GRDB writes complete before process exits.
    // Handles both zoomed (range replace) and non-zoomed (full replace) cases.
    editorState?.flushContentToDatabase()

    // Remove existing dead code:
    // The old `Task { await state.zoomOut() }` was fire-and-forget —
    // the process exits before the Task can run. flushContentToDatabase()
    // already handles zoomed state via replaceBlocksInRange().

    removeEscapeKeyMonitor()
    // Remove Esc key monitor (existing, unchanged)
}
```

**Changes:** Remove the existing `Task { await state.zoomOut() }` block (lines 228-232) — it is dead code that never completes before process exit. Replace with the synchronous `flushContentToDatabase()` which correctly handles both zoomed and non-zoomed cases.

## Additional Failure Paths (Future Work)

Code review identified additional content-drop scenarios beyond the project-switch bug. These are separate issues to investigate after the primary fix:

1. **1500ms `.editorTransition` window:** After switching CodeMirror→Milkdown, the `contentState == .idle` guard in `handleContentPush` silently drops all pushes for 1500ms. Edits during this window are lost.
2. **200ms grace period:** The `handleContentPush` guard at line 654-656 drops pushes within 200ms of the last Swift→JS push if content differs. Fast paste-after-load could be lost.
3. **No timeout on `.bibliographyUpdate` state:** If the bibliography async task hangs, `contentState` stays non-idle indefinitely, silently dropping all subsequent edits.

## Verification

1. **Reproduce the original bug:**
   - Open project A, add a link via Cmd+K, add some text after it
   - Immediately switch to project B
   - Switch back to project A
   - **Expected:** Link and text are preserved

2. **Test rapid switching:**
   - Type text, immediately switch projects (within 100ms)
   - Switch back — content should be preserved

3. **Test project close:**
   - Edit content, close the project
   - Reopen — content should be preserved

4. **Test app quit:**
   - Edit content, Cmd+Q
   - Reopen app and project — content should be preserved

5. **Test zoom mode:**
   - Zoom into a section, edit content
   - Switch projects while zoomed
   - Switch back — zoomed edits should be preserved

6. **Regression check:**
   - Normal editing flow (no switching) still works
   - Editor mode toggle (Cmd+/) still preserves content
   - Drag-drop reordering still works
