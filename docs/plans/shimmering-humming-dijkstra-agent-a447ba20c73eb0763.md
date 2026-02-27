# Round 3 Code Review: Content Loss on Project Switch Fix

## Verification of Previous Round Issues

### Round 1 Issues -- Both Addressed

**Issue 1: flushContentToDatabase() then blockSyncService.flushNow() causes block ID mismatch**
Status: ADDRESSED. The plan explicitly states on line 82: "Why no blockSyncService.flushNow():" and explains the ID conflict mechanism. `flushAllPendingContent()` calls only `flushContentToDatabase()`, never `flushNow()`.

**Issue 2: Race between flushNow() and pollBlockChanges()**
Status: ADDRESSED. `flushNow()` is removed entirely from the picture, making this moot.

### Round 2 Issues -- All Addressed

**Issue 3: BlockSyncService poll timer can fire during await suspension points in flushAllPendingContent()**
Status: ADDRESSED. Plan Step 2 (lines 88-115) explicitly reorders `handleProjectOpened()` to call `blockSyncService.stopPolling()` FIRST, before `await flushAllPendingContent()`. The plan includes a detailed explanation of why this ordering matters.

**Issue 4: fetchContentFromWebView() continuation could leak if WebView crashes**
Status: PARTIALLY ADDRESSED. The plan documents that `fetchContentFromWebView()` returns nil on JS error (line 47-48), and the guard at line 58 handles the nil case. However, the plan does NOT add an explicit timeout. If the WebView process is hung (not crashed, but stuck), the `evaluateJavaScript` completion handler may never fire, which would permanently suspend `flushAllPendingContent()`. See NEW ISSUE 1 below.

**Issue 5: Remove dead Task { await state.zoomOut() } in applicationWillTerminate**
Status: ADDRESSED. The plan at line 160 explicitly acknowledges this is "redundant for data safety" and the proposed Step 4 code replaces it with a synchronous `flushContentToDatabase()` call. However, the plan text says "The existing fire-and-forget Task ... will never complete" but the proposed code in Step 4 does NOT show the removal of the `Task { await state.zoomOut() }` block. The proposed code shows adding `editorState?.flushContentToDatabase()` but the existing `Task { await state.zoomOut() }` block (lines 228-232 of AppDelegate.swift) should be explicitly removed or the plan should state it is being removed. Otherwise the implementer may leave both in place.

**Issue 6: Consider making performProjectClose() async for full WebView fetch**
Status: ACKNOWLEDGED but DEFERRED. The plan keeps `performProjectClose()` synchronous (Step 3, line 121-122) with the rationale that "editorState.content is current (JS 50ms debounce has fired by button click time)." This is a reasonable judgment -- the button click latency (typically 50-200ms) exceeds the JS debounce (50ms), so the Swift-side content binding should already be current by the time the user clicks close.

---

## Plan Alignment Analysis

The plan is well-structured with four concrete steps. The approach is sound: fetch from WebView, flush to DB, then tear down. The plan correctly identifies that `flushContentToDatabase()` is the right single call for block persistence (it does a full re-parse + replace, avoiding incremental sync issues).

### Reordering of handleProjectOpened() -- Correctness Check

The proposed order is:
1. `blockSyncService.stopPolling()` -- synchronous Timer.invalidate()
2. `await flushAllPendingContent()` -- async (WebView fetch + sync DB writes)
3. `editorState.stopObserving()` -- cancels ValueObservation tasks
4. Cancel remaining services
5. JS `resetForProjectSwitch()`
6. `editorState.resetForProjectSwitch()`
7. `configureForCurrentProject()`

This is correct. `stopPolling()` calls `Timer.invalidate()` which is synchronous and immediate (line 62-64 of BlockSyncService.swift). Once the timer is invalidated, no new `pollBlockChanges()` can be scheduled. Any already-scheduled `Task { @MainActor in await self?.pollBlockChanges() }` would find `isPolling` false but could proceed -- however, since we are on @MainActor and the `await` in step 2 yields to the cooperative executor, a previously-scheduled poll Task COULD execute during the suspension.

Wait -- this needs closer examination. See NEW ISSUE 2 below.

---

## New Issues Found in Round 3

### NEW ISSUE 1 (Important): fetchContentFromWebView() has no timeout guard

The proposed `fetchContentFromWebView()` wraps `evaluateJavaScript` in `withCheckedContinuation`. If the WKWebView process is hung (not crashed), the completion handler may never fire. This would cause `flushAllPendingContent()` to suspend forever, blocking the project switch.

**WKWebView crash behavior:** When the WebView process crashes, WKWebView calls completion handlers with an error (`WKError.webContentProcessTerminated`). So a full crash is handled. The risk is a WebView that is alive but unresponsive (e.g., infinite JS loop, though Milkdown's architecture makes this unlikely).

**Recommendation:** Add a timeout race, similar to `waitForContentAcknowledgement()` in EditorViewState+Zoom.swift (lines 15-37). A 2-second timeout would be appropriate:

```swift
private func fetchContentFromWebView() async -> String? {
    guard let webView = findBarState.activeWebView else { return nil }

    return await withTaskGroup(of: String?.self) { group in
        group.addTask {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript("window.FinalFinal.getContent()") { result, error in
                    continuation.resume(returning: result as? String)
                }
            }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
```

**Severity: Important** -- the project switch would hang indefinitely in the rare case of an unresponsive WebView.

### NEW ISSUE 2 (Critical): Poll timer's already-dispatched Task can race with flushAllPendingContent()

The `Timer.scheduledTimer` callback (BlockSyncService.swift line 54-58) dispatches a `Task { @MainActor in await self?.pollBlockChanges() }` each time it fires. `Timer.invalidate()` prevents FUTURE firings, but if the timer already fired and dispatched a Task that is waiting in the @MainActor executor queue, that Task will execute when the main actor yields.

Sequence:
```
T=0ms    Timer fires, dispatches Task A: { await pollBlockChanges() }
T=1ms    handleProjectOpened() begins
T=2ms    blockSyncService.stopPolling() -- invalidates timer (no NEW fires)
T=3ms    await flushAllPendingContent() -- yields to executor
T=4ms    Executor runs Task A (already queued) -> pollBlockChanges() begins
         pollBlockChanges() reads JS block changes, writes to DB
T=5ms    flushAllPendingContent() resumes, calls flushContentToDatabase()
         flushContentToDatabase() re-parses content, calls replaceBlocks()
         -- this replaces ALL blocks with new UUIDs, which is fine
```

Actually, on further analysis: `flushContentToDatabase()` calls `db.replaceBlocks()` which does a full delete-and-insert. So even if `pollBlockChanges()` wrote incremental changes at T=4ms, `flushContentToDatabase()` at T=5ms would overwrite everything with the complete content. The data ends up correct.

BUT there is a subtlety: if `pollBlockChanges()` at T=4ms triggers a DB observation event, that could modify `editorState.sections` while `flushAllPendingContent()` is in progress. The `editorState.stopObserving()` call happens AFTER `flushAllPendingContent()` in the proposed code. So the observation is still active during the flush.

However, `flushContentToDatabase()` is synchronous (no await), so there is no yield point during which the observation could fire and interfere. The observation runs in a Task that yields to the MainActor executor, and since `flushContentToDatabase()` holds the MainActor without yielding, no observation update can interleave with it.

**Revised assessment:** The race exists but is benign because `flushContentToDatabase()` does a full replace that overwrites any incremental poll writes. The poll might do unnecessary work, but it cannot cause data loss.

**Severity: Not an issue.** The plan's ordering is correct and sufficient. Documenting the reasoning would be valuable but is not required.

### NEW ISSUE 3 (Important): flushAllPendingContent() writes to OLD project's database -- but which database?

The plan says (line 97): "Flush all pending content to OLD project's database before switching." This is correct in intent. But look at the code path:

1. `flushAllPendingContent()` calls `editorState.flushContentToDatabase()`
2. `flushContentToDatabase()` (EditorViewState+Zoom.swift line 348-423) uses `self.projectDatabase` and `self.currentProjectId`
3. These are set in `startObserving()` (EditorViewState.swift line 212-213)

The question is: has `editorState.projectDatabase` been changed to the NEW project's database before `flushAllPendingContent()` is called?

Looking at the proposed `handleProjectOpened()`:
```
1. blockSyncService.stopPolling()
2. await flushAllPendingContent()          // <-- uses editorState.projectDatabase
3. editorState.stopObserving()
4. ...cancel services...
5. JS resetForProjectSwitch()
6. editorState.resetForProjectSwitch()     // <-- does NOT clear projectDatabase
7. await configureForCurrentProject()      // <-- THIS calls startObserving() which
                                           //     sets editorState.projectDatabase to NEW db
```

`editorState.projectDatabase` is still pointing at the OLD database at step 2. Good -- this is correct.

But wait -- what calls `handleProjectOpened()`? It is triggered by a notification (line 115 of ContentView.swift: `onOpened: { await handleProjectOpened() }`). The notification is fired after `DocumentManager` has already opened the new project (which sets `documentManager.projectDatabase` to the new DB). But `editorState.projectDatabase` is only updated in `configureForCurrentProject()` -> `startObserving()`. So at step 2, `editorState.projectDatabase` still points to the old project's database.

**This is correct.** No issue here. Just confirming the plan's assertion is accurate.

### NEW ISSUE 4 (Suggestion): performProjectClose() should flush BEFORE autoBackupService.projectWillClose()

In the proposed Step 3 (line 124-135), the plan adds `editorState.flushContentToDatabase()` at the top of `performProjectClose()`. This is before the auto-backup Task. Good.

But looking at the current code (line 255-278), `autoBackupService.projectWillClose()` creates a backup snapshot of the current database state. If the flush happens first (as proposed), the backup will include the just-flushed content. This is the correct order.

**No issue** -- just confirming the ordering is correct.

### NEW ISSUE 5 (Important): applicationWillTerminate should explicitly remove the dead zoomOut Task

The plan's Step 4 adds `editorState?.flushContentToDatabase()` to `applicationWillTerminate` but the proposed code snippet (lines 143-158) does not show the existing `Task { await state.zoomOut() }` block being removed. The plan text (line 160) says it is "redundant for data safety" but does not explicitly say "remove it."

If the implementer leaves both in place:
1. `editorState?.flushContentToDatabase()` runs synchronously, persists content
2. `Task { await state.zoomOut() }` is created but the process exits before it runs

This is harmless but confusing. The dead Task should be removed for code clarity.

**Recommendation:** The plan should explicitly state: "Remove the existing `Task { await state.zoomOut() }` block (lines 228-232) and replace with the synchronous flush."

**Severity: Suggestion** -- leaving both is harmless but misleading.

### NEW ISSUE 6 (Important): editorState.content could be empty string if handleContentPush guard rejected the latest edit

The plan's `flushAllPendingContent()` has this logic (line 58-61):
```swift
if let freshContent = await fetchContentFromWebView(), !freshContent.isEmpty {
    editorState.content = freshContent
}
guard !editorState.content.isEmpty else { return }
```

This correctly handles the case where WebView content is newer than `editorState.content`. But there is a subtle scenario:

1. User makes an edit
2. JS `contentChanged` message fires
3. `handleContentPush` REJECTS the push (e.g., within 200ms grace period, or `contentState != .idle`)
4. `editorState.content` does NOT have the latest edit
5. Project switch triggers `flushAllPendingContent()`
6. `fetchContentFromWebView()` returns the latest content from WebView

Step 6 rescues the data that was lost at step 3. This is exactly the right behavior. The WebView fetch is essential for catching edits that the push-based flow dropped.

**No issue** -- the plan handles this correctly. The WebView fetch is the key safety net.

### NEW ISSUE 7 (Suggestion): Consider stopping the MilkdownCoordinator's 3s fallback polling timer too

Looking at MilkdownCoordinator+MessageHandlers.swift lines 672-679, there is a separate 3s polling timer (`pollingTimer`) in the Milkdown coordinator. This timer calls `pollContent()` which reads stats and section title from JS. This is harmless during project switch (it only reads, never writes to DB), but it could cause confusing debug logs or JS errors after `resetForProjectSwitch()` clears the editor state.

The existing code already handles this -- `pollContent()` has guards for `isResettingContentBinding` and `contentState == .idle`. So this is not a data issue.

**Severity: Suggestion** -- no action needed, just noting for completeness.

### NEW ISSUE 8 (Critical): ContentView is a struct -- private methods cannot capture self mutably

**This is the most important finding of this review.**

`ContentView` is defined as `struct ContentView: View` (ContentView.swift line 41). In Swift, you cannot define `async` methods on a struct that capture `self` mutably. The proposed `fetchContentFromWebView()` and `flushAllPendingContent()` are `private func` on the `extension ContentView` in the lifecycle file.

BUT -- these methods access `@State` properties (`findBarState`, `editorState`, `sectionSyncService`, `annotationSyncService`). In SwiftUI, `@State` properties are reference-wrapped -- the struct's value type does not matter because `@State` provides a stable reference. So `findBarState.activeWebView` works fine across `await` suspension points.

Similarly, `editorState.content`, `editorState.flushContentToDatabase()`, `sectionSyncService.syncNow()`, and `annotationSyncService.syncNow()` all access `@State` properties which are reference-stable.

**Revised assessment:** This is NOT an issue. SwiftUI's `@State` and `@Observable` provide reference semantics. The proposed methods will work correctly on a struct View.

---

## Summary

### Issues From Rounds 1-2: All Addressed
- Round 1 issues 1-2: Fully addressed (flushNow removed)
- Round 2 issue 3: Fully addressed (stopPolling before flush)
- Round 2 issue 4: Partially addressed (see NEW ISSUE 1 -- timeout recommended)
- Round 2 issue 5: Addressed in spirit but ambiguous (see NEW ISSUE 5)
- Round 2 issue 6: Acknowledged and deferred with reasonable justification

### New Issues Found

| # | Severity | Description |
|---|----------|-------------|
| 1 | Important | fetchContentFromWebView() needs a timeout to prevent indefinite suspension if WebView is hung |
| 2 | Not an issue | Poll timer race is benign due to full-replace semantics of flushContentToDatabase() |
| 3 | Not an issue | Database pointer confirmed correct (OLD project's DB at flush time) |
| 4 | Not an issue | performProjectClose() flush-before-backup ordering is correct |
| 5 | Suggestion | Plan should explicitly state removal of the dead zoomOut Task in applicationWillTerminate |
| 6 | Not an issue | WebView fetch correctly rescues edits dropped by handleContentPush guards |
| 7 | Suggestion | MilkdownCoordinator's 3s polling timer is harmless but noted for completeness |
| 8 | Not an issue | struct ContentView @State properties provide reference semantics, no capture issue |

### Actionable Items for Plan Update

1. **Add a timeout to fetchContentFromWebView()** (Important) -- Use a TaskGroup race pattern similar to the existing `waitForContentAcknowledgement()` in EditorViewState+Zoom.swift. A 2-second timeout is appropriate.

2. **Clarify removal of dead zoomOut Task in applicationWillTerminate** (Suggestion) -- The plan's Step 4 code should explicitly show the removal of lines 228-232 of AppDelegate.swift, not just the addition of the new flush call.

### Overall Assessment

The plan is solid. The core approach (stop polling -> fetch from WebView -> flush to DB -> tear down) is correct and handles the data loss scenario well. The `fetchContentFromWebView()` as a safety net for edits dropped by the push-based guards is a key insight. The only actionable item of real concern is the missing timeout on the WebView fetch, which could cause a hang in edge cases.
