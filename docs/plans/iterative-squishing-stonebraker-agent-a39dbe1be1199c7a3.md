# Code Review: Race Condition Fixes Plan

**Reviewed:** `docs/plans/iterative-squishing-stonebraker.md`
**Reviewer:** Code Review Agent
**Date:** 2026-03-01

---

## 1. Diagnosis Verification (Is each diagnosis correct?)

### Fix 1: CheckedContinuation Double-Resume -- CONFIRMED REAL

The diagnosis is correct. In `EditorViewState+Zoom.swift` (lines 15-46), the `waitForContentAcknowledgement()` method has a genuine TOCTOU race:

```swift
// Timeout path (line 24-27):
guard !isAcknowledged else { return }
isAcknowledged = true
contentAckContinuation?.resume()
contentAckContinuation = nil

// Acknowledgement path (line 42-45):
guard !isAcknowledged else { return }
isAcknowledged = true
contentAckContinuation?.resume()
contentAckContinuation = nil
```

Because both paths run on `@MainActor` (serial), the actual double-resume risk is limited to the case where the timeout `Task` fires and the `acknowledgeContent()` is called before the guard's result is evaluated. On `@MainActor`, each execution block runs to completion, so one will always see `isAcknowledged = true` set by the other. **However**, there is a real problem: the timeout path runs in a `Task` that captures `[weak self]` -- but the `timeoutTask` is cancelled _after_ the continuation is already resumed by `acknowledgeContent()`. If the timeout fires exactly at the same runloop turn as the ack, both Tasks can be dispatched to the main actor's queue and run sequentially, but `timeoutTask.cancel()` on line 36 happens _after_ the continuation has already been stored. The nil-before-resume pattern proposed is a strictly better approach.

Additionally, the watchdog in `EditorViewState.swift` (lines 80-81) uses the same unsafe pattern:
```swift
self.contentAckContinuation?.resume()
self.contentAckContinuation = nil
```
This is a third code path that could conflict with the other two. The plan correctly identifies this.

**Verdict: Diagnosis is sound. Fix is appropriate.**

### Fix 2: flushContentToDatabase TOCTOU -- PARTIALLY CORRECT, NUANCE MISSED

The plan states that the metadata pre-read in `flushContentToDatabase()` (lines 357-365 of `EditorViewState+Zoom.swift`) is redundant because `replaceBlocks()` and `replaceBlocksInRange()` already preserve metadata internally.

Looking at the actual code:

- `flushContentToDatabase()` reads existing blocks, builds `metadata: [String: SectionMetadata]`, then passes it to `BlockParser.parse()` as `existingSectionMetadata`.
- `replaceBlocks()` in `Database+BlocksReorder.swift` (lines 41-83) builds its own `metadataByTitle` lookup internally and applies it during insertion.

**The plan is correct that `replaceBlocks`/`replaceBlocksInRange` preserve metadata internally.** However, there is a subtlety: `BlockParser.parse()` with `existingSectionMetadata` applies metadata to the parsed `Block` objects _before_ they are passed to `replaceBlocks()`. Then `replaceBlocks()` applies metadata _again_ from its own DB read. This means the metadata is applied twice -- once from the potentially-stale pre-read, and once from the atomic in-transaction read. The second application wins, making the first redundant.

**However, passing `nil` to `BlockParser.parse()` changes its behavior.** The `existingSectionMetadata` parameter is used during parsing to set initial values on the `Block` objects. If `replaceBlocks()` always overrides those values from its own DB read, then `nil` is safe. I verified that `replaceBlocks()` does unconditionally apply `metadataByTitle` when a title match is found (lines 69-78 of `Database+BlocksReorder.swift`), so the pre-set values from `BlockParser.parse()` are indeed overwritten.

**Verdict: Fix is correct. The TOCTOU gap exists but is masked by the double-application. Removing the redundant read is the right call.**

### Fix 3: Debounce Generation Counter -- CONFIRMED REAL

The plan correctly identifies that `Task.isCancelled` is cooperative and may not propagate in time. Looking at `SectionSyncService.swift` lines 130-143:

```swift
debounceTask?.cancel()
debounceTask = Task {
    try? await Task.sleep(for: debounceInterval)
    guard !Task.isCancelled else { return }
    await syncContent(markdown, zoomedIds: zoomedIds)
}
```

Between `debounceTask?.cancel()` and the old task checking `Task.isCancelled`, the old task could already be past the sleep and about to call `syncContent()`. A generation counter is the standard solution for this.

The same pattern exists in `AnnotationSyncService.swift` (lines 89-94).

**Verdict: Diagnosis and fix are both correct.**

### Fix 4: Stale Poll Detection via Content Generation Counter -- CONFIRMED REAL

The plan identifies that polling starts a JS `evaluateJavaScript` call, and by the time the callback arrives, `contentState` may have changed. Looking at `MilkdownCoordinator+MessageHandlers.swift` lines 702-726:

```swift
func pollContent() {
    guard !isCleanedUp, isEditorReady, let webView else { return }
    guard !isResettingContentBinding.wrappedValue else { return }
    guard contentState == .idle else { return }
    // ^^^ This check passes, but by the time the callback runs...

    webView.evaluateJavaScript("window.FinalFinal.getPollData()") { [weak self] result, _ in
        // ...contentState could be .zoomTransition now
        // The result is stale but no guard here
```

However, note that the current polling (3s fallback) only fetches stats and section title -- it does **not** update content. The push-based `handleContentPush()` does have a `contentState == .idle` guard. So the stale poll issue for content is already mitigated by the push-based flow.

**The stale data risk is primarily in `BlockSyncService.pollBlockChanges()`** which does modify the database based on polled results. The `isSyncSuppressed` guard protects it, but the plan's point about async gaps is valid.

**Verdict: Diagnosis is correct, though severity for the editor coordinators is lower than stated since content polling was replaced by push-based messaging. The real risk is in `BlockSyncService.pollBlockChanges()`.**

### Fix 5: Flag Consolidation -- DIAGNOSIS CORRECT, EXECUTION RISKY

The plan correctly identifies 6 scattered flags:
1. `EditorViewState.isObservationSuppressed` -- used during drag (lines 487-493 of `ContentView.swift`)
2. `EditorViewState.isZoomingContent` -- rendering directive (kept, correct)
3. `EditorViewState.isResettingContent` -- used during project switch AND bibliography/footnote updates
4. `SectionSyncService.isSyncSuppressed` -- used during drag
5. `BlockSyncService.isSyncSuppressed` -- used during drag/zoom/bibliography/push
6. `AnnotationSyncService.isSyncSuppressed` -- used during annotation text edit

**Verdict: Diagnosis is sound. See Section 3 for risk analysis.**

---

## 2. Race Conditions the Plan MISSED

### MISSED-1: `handleAnnotationTextUpdate` Time-Based Suppression (IMPORTANT)

In `ContentView+ContentRebuilding.swift` lines 240-280:

```swift
func handleAnnotationTextUpdate(_ annotation: AnnotationViewModel, newText: String) {
    annotationSyncService.isSyncSuppressed = true
    // ... do work ...
    Task {
        try? await Task.sleep(for: .milliseconds(100))
        annotationSyncService.isSyncSuppressed = false
    }
}
```

This time-based re-enable is fragile. If the annotation update takes longer than 100ms (e.g., a slow DB write), the suppression is removed too early. Under Fix 5, this would need to set `contentState` to a non-idle value, but there is no appropriate `EditorContentState` case for an annotation edit. The plan's Fix 5 does not mention this code path.

### MISSED-2: `onDragStarted`/`onDragEnded` Outside contentState (IMPORTANT)

In `ContentView.swift` lines 486-496:

```swift
onDragStarted: {
    editorState.isObservationSuppressed = true
    sectionSyncService.isSyncSuppressed = true
    sectionSyncService.cancelPendingSync()
    blockSyncService.isSyncSuppressed = true
},
onDragEnded: {
    editorState.isObservationSuppressed = false
    sectionSyncService.isSyncSuppressed = false
    blockSyncService.isSyncSuppressed = false
}
```

These callbacks set flags but do NOT set `contentState`. The `contentState` is only set to `.dragReorder` later, inside `finalizeSectionReorder()` (line 241 of `ContentView+SectionManagement.swift`), which is called when the drop actually happens. Between `onDragStarted` and the actual drop, `contentState` remains `.idle`.

Under Fix 5, if services check `contentState != .idle` instead of their own flags, the suppression during the drag-but-before-drop phase would be lost. The plan mentions removing `isObservationSuppressed` and relying on `contentState`, but the drag gesture itself does not set `contentState`.

This is a **gap in Fix 5** that would cause regressions: ValueObservation updates would not be suppressed during the drag gesture, and section/block sync would continue to fire.

### MISSED-3: `isResettingContent` is NOT a Pure Suppression Flag (IMPORTANT)

The plan's Fix 5 says to replace `isResettingContent` with `contentState = .projectSwitch`. But `isResettingContent` is used in two different contexts:

1. **Project switch** (`ContentView+ProjectLifecycle.swift` line 208) -- a legitimate `contentState` transition.
2. **Bibliography/footnote updates** (`ContentView.swift` lines 162, 191, 241) -- where `contentState` is ALREADY set to `.bibliographyUpdate`. Here, `isResettingContent` serves a DIFFERENT purpose: it tells `updateNSView` not to call `setContent()` because the content will be pushed atomically via `setContentWithBlockIds()`.

Replacing `isResettingContent` with a `contentState` check would break the bibliography/footnote path, because `contentState` is already `.bibliographyUpdate` there. The `isResettingContent` flag serves as a **rendering directive** (like `isZoomingContent`), not a suppression flag.

The plan should keep `isResettingContent` as-is, similar to how it keeps `isZoomingContent`.

### MISSED-4: `.didZoomOut` Notification Fires Without State Protection (SUGGESTION)

In `ContentView.swift` lines 304-342, the `.didZoomOut` handler runs `annotationSyncService.contentChanged()` and `bibliographySyncService.checkAndUpdateBibliography()` without checking `contentState`. This is because `contentState` was just set to `.idle` by `zoomOut()`. However, if another transition starts between the `contentState = .idle` in `zoomOut()` and the notification handler running, the annotation sync could fire during a non-idle state. This is a minor timing issue since both run on `@MainActor`, but it is worth noting that `.didZoomOut` is posted synchronously from within `zoomOut()` before `pushBlockIds()` completes.

Actually, looking more carefully: `.didZoomOut` is posted from `zoomOut()` at line 321:
```swift
contentState = .idle
NotificationCenter.default.post(name: .didZoomOut, object: nil)
```

And the handler in `ContentView.swift` line 314 checks `editorState.contentState == .idle`. Since `contentState` was just set to `.idle`, this guard passes. But the sidebar's `onZoomOut` closure (line 477-484) also sets `blockSyncService.isSyncSuppressed = true` and calls `pushBlockIds()`. The `pushBlockIds()` function sets `isSyncSuppressed = true` again with `defer { false }`. There is a window where the `.didZoomOut` handler runs while `blockSyncService.isSyncSuppressed` is still `true` from the sidebar. This is fine because the `.didZoomOut` handler doesn't use `BlockSyncService`, but it shows the complexity of the flag interactions.

### MISSED-5: `contentChanged` in `handleContentPush` Bypasses `isSyncSuppressed` for Annotations (SUGGESTION)

In `ViewNotificationModifiers.swift` lines 292-296, the `onChange(of: editorState.content)` handler calls `annotationSyncService.contentChanged(newValue)` whenever content changes and `contentState == .idle`. The annotation service's own `isSyncSuppressed` flag is not checked here -- it is checked inside `contentChanged()` (line 84 of `AnnotationSyncService.swift`). This is correct architecturally, but if Fix 5 moves the check to `contentState != .idle`, the 100ms time-based suppression in `handleAnnotationTextUpdate` (MISSED-1) would no longer be protected.

### MISSED-6: Source Mode Block Re-parse Has Same Debounce Race as Fix 3 (SUGGESTION)

In `ViewNotificationModifiers.swift` lines 299-337, the source mode block re-parse path uses the same cancel-and-recreate-Task pattern:
```swift
editorState.blockReparseTask?.cancel()
editorState.blockReparseTask = Task {
    try? await Task.sleep(for: .milliseconds(1000))
    guard !Task.isCancelled else { return }
    // ...
}
```

This has the same cooperative cancellation gap that Fix 3 addresses for `SectionSyncService` and `AnnotationSyncService`. A generation counter should be applied here too.

---

## 3. Will the Fixes Introduce New Problems?

### Fix 5 Risk: `isSyncSuppressed = true` Without Non-Idle `contentState`

The plan says services should check `contentState != .idle` instead of their own `isSyncSuppressed` flags. The question is: are there places where `isSyncSuppressed = true` but `contentState` is `.idle`?

**YES, there are several:**

1. **Drag started** (`ContentView.swift` line 488-490): `sectionSyncService.isSyncSuppressed = true` and `blockSyncService.isSyncSuppressed = true` are set, but `contentState` remains `.idle` until `finalizeSectionReorder()` is called. If Fix 5 replaces the flag check with `contentState != .idle`, sync operations would fire during the drag gesture.

2. **Zoom sidebar callbacks** (`ContentView.swift` lines 441, 470, 479): `blockSyncService.isSyncSuppressed = true` is set before the `Task` that calls `zoomToSection()`/`zoomOut()`. The `contentState` is set to `.zoomTransition` inside those functions, but there is a gap between the `isSyncSuppressed = true` and the start of the async function. If a poll fires in that gap under the new scheme, it would not be suppressed.

3. **Annotation text edit** (`ContentView+ContentRebuilding.swift` line 242): `annotationSyncService.isSyncSuppressed = true` is set for 100ms, but `contentState` is `.idle` throughout. This suppression would be completely lost.

**These are real regression risks. Fix 5 as written would cause at least 3 categories of bugs.**

### Fix 4 Risk: Generation Counter Only Increments on idle->non-idle

The plan says:
```swift
if oldValue == .idle && contentState != .idle {
    contentGeneration += 1
}
```

The question: could content change while already in a non-idle state?

**YES.** During a `.bibliographyUpdate` state, the bibliography content is rebuilt and pushed via `setContentWithBlockIds()`. If another bibliography notification fires while the first is still processing (the `Task` on line 174 of `ContentView.swift` hasn't completed yet), the generation counter would not increment. However, the `contentState == .idle` guard at line 142 prevents re-entry, so this specific scenario is blocked by the existing guard.

A more realistic scenario: during `.zoomTransition`, the content is set (line 187 of `EditorViewState+Zoom.swift`), then `waitForContentAcknowledgement()` is called. If a poll fires and checks the generation counter, it would correctly see a stale generation and discard. The idle->non-idle increment is sufficient because:
- Any poll that started before the transition has the old generation.
- Any poll that starts during the transition is blocked by the `contentState == .idle` guard.
- Any poll that starts after returning to idle has the new generation.

**Verdict: The idle->non-idle increment is correct for the polling use case.** However, if `contentState` transitions directly between two non-idle states (e.g., `.zoomTransition` in `zoomOut()` line 247 when called from `zoomToSection()`), no increment occurs. The `callerManagedState` logic in `zoomOut()` (line 245-248) handles this case -- it does not set `contentState` again because it is already `.zoomTransition`. This is fine because no polls can be running during a non-idle state.

### Fix 1 Risk: None Identified

The nil-before-resume pattern on `@MainActor` is safe and well-established.

### Fix 2 Risk: None Identified

Passing `nil` to `BlockParser.parse()` just means initial metadata values are default. Since `replaceBlocks()`/`replaceBlocksInRange()` override metadata from their own DB reads, the end result is identical.

### Fix 3 Risk: None Identified

A generation counter is a pure improvement with no side effects.

---

## 4. Implementation Order Assessment

The plan states: **Fix 2 -> 3 -> 5 -> 4 -> 1** (but the summary says "1->2->3->4->5").

The stated order in the plan text (Fix 2 -> 3 -> 5 -> 4 -> 1) has a dependency issue:

- **Fix 5 should come LAST**, not third. It is the riskiest change (as analyzed above) and touches the most files. It also depends on understanding all the patterns that Fixes 1-4 establish. If Fix 5 introduces regressions, they could mask or interact with issues from the other fixes.

- **Fix 1 should come FIRST**. It is the most critical (a double-resume is a crash, not just wrong behavior) and is completely self-contained. No other fix depends on it.

**Recommended order: Fix 1 -> Fix 2 -> Fix 3 -> Fix 4 -> Fix 5**

This is safest because:
1. Fix 1 eliminates a crash -- highest priority.
2. Fix 2 is a small, safe deletion with no side effects.
3. Fix 3 is additive (adds a counter) with no interaction with other fixes.
4. Fix 4 is additive (adds a counter + guards) with no interaction.
5. Fix 5 is a refactor that should be done last after all other fixes are stable and tested. It also needs significant rework (see Section 5).

---

## 5. NotificationCenter Patterns That Could Fire Between State Transitions

Several `NotificationCenter` patterns could cause issues not covered by the plan:

### `.bibliographySectionChanged` and `.notesSectionChanged`

These fire from `BibliographySyncService` and `FootnoteSyncService` respectively, triggered by database observation. They are guarded by `contentState == .idle` (lines 142, 185 of `ContentView.swift`). However:

- The guard happens at receive time. If a notification is enqueued while `contentState` is non-idle and delivered after `contentState` returns to `.idle`, it will be processed with potentially stale data.
- The `suppressNextBibliographyRebuild` flag (line 77) handles one specific case (project switch), but doesn't handle general timing issues.

**Risk level: Low.** Since `NotificationCenter.default.publisher(for:)` delivers on the same runloop as the post, and state transitions are all on `@MainActor`, the delivery is synchronous. The guard is evaluated at delivery time, which is correct.

### `.footnoteInsertedImmediate`

This notification is posted from within `evaluateJavaScript` completion handlers in both coordinators. The handler in `ContentView.swift` (lines 221-303) checks `contentState == .idle` and queues the label if busy. This is well-designed.

### `.didZoomOut`

As noted in MISSED-4, this notification is posted synchronously within `zoomOut()` after `contentState = .idle`. The handler runs various sync operations. Since the sidebar's zoom-out closure also calls `blockSyncService.pushBlockIds()` in a `Task`, and `pushBlockIds()` sets `isSyncSuppressed = true`, there is a potential conflict. However, since `pushBlockIds` runs in a `Task` (async), the `.didZoomOut` handler completes first, which is the desired behavior.

### `.toggleEditorMode` chain

The editor switch goes through a two-phase protocol:
1. `willToggleEditorMode` -> coordinator saves cursor -> posts `.didSaveCursorPosition`
2. `.didSaveCursorPosition` handler checks `contentState == .idle` (line 151 of `ViewNotificationModifiers.swift`), then posts `.toggleEditorMode`
3. `.toggleEditorMode` handler sets `contentState = .editorTransition`

The rapid Cmd+/ guard on line 151 is important -- without it, a second toggle during transition would corrupt state. This is already correctly handled.

### `.scrollToSection`

This notification handler (line 343) performs a database read but does not check `contentState`. During a zoom transition, it could read stale block data. This is a low-severity issue since scroll is a non-destructive operation.

---

## 6. Summary of Recommendations

### Critical Issues with the Plan

1. **Fix 5 must account for `onDragStarted` not setting `contentState`.** Either add a `case dragging` state set from `onDragStarted`, or keep the service-level `isSyncSuppressed` flags specifically for drag operations.

2. **Fix 5 must keep `isResettingContent` as a separate flag.** It is a rendering directive, not a suppression flag. It tells `updateNSView` to skip content pushes during atomic operations. It cannot be replaced by `contentState` because it is used in contexts where `contentState` is already set to something else (e.g., `.bibliographyUpdate`).

3. **Fix 5 must handle `handleAnnotationTextUpdate`'s 100ms suppression.** Either wrap it in a `contentState` transition or keep the per-service flag for this specific case.

### Important Improvements

4. **Apply the generation counter pattern from Fix 3 to `blockReparseTask` in `ViewNotificationModifiers.swift`** (the source-mode debounced re-parse). Same cooperative cancellation race.

5. **Re-order implementation: Fix 1 -> 2 -> 3 -> 4 -> 5.** The crash fix should come first, the largest refactor should come last.

### Suggestions

6. The plan's Fix 4 generation counter could use `contentGeneration` as an `Int` that increments on ANY non-idle transition, not just idle->non-idle, to be more defensive. The current approach is correct but less robust against future state machine changes.

7. Consider adding a `case annotationEdit` to `EditorContentState` for the `handleAnnotationTextUpdate` path, replacing the 100ms sleep with a proper state transition. This would make Fix 5 cleaner.
