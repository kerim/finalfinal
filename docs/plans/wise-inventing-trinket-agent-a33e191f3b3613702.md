# Second Review: Revised Typing Latency Plan

## Summary

The revised plan at `docs/plans/wise-inventing-trinket.md` is substantially improved from the first round. It correctly addresses all eight issues identified previously. However, this second review against the actual codebase surfaces **three genuine issues** and **two clarifications** that need attention before implementation.

---

## Issue 1 (Important): CodeMirror updateListener closure captures stale `update.view.state`

**Plan reference:** Step 1, CodeMirror JS side (lines 58-70)

**The problem:** The plan proposes this pattern:

```js
EditorView.updateListener.of((update) => {
  if (update.docChanged) {
    if (cmPushTimer) clearTimeout(cmPushTimer);
    cmPushTimer = setTimeout(() => {
      const raw = update.view.state.doc.toString(); // includes anchors
      window.webkit?.messageHandlers?.contentChanged?.postMessage(raw);
    }, 50);
  }
})
```

The `update` object is captured in the setTimeout closure, but by the time the 50ms debounce fires, that `update.view.state` may be stale if further keystrokes arrived. The `update.view` reference does point to the live EditorView instance, so `update.view.state` actually accesses the view's *current* state at closure execution time (EditorView.state is a getter). However, this behavior is an implementation detail of CM6 and is not guaranteed by the API.

**Recommendation:** Use the view directly from module state (like `getEditorView()`) rather than relying on the closure-captured `update.view`:

```js
cmPushTimer = setTimeout(() => {
  const view = getEditorView();
  if (!view) return;
  const raw = view.state.doc.toString();
  window.webkit?.messageHandlers?.contentChanged?.postMessage(raw);
}, 50);
```

This is more robust and explicitly reads the current state. The `getEditorView()` accessor already exists in `editor-state.ts` (via `setEditorView`/getter pattern).

**Severity:** Important -- could cause intermittent stale-content pushes on very fast typing.

---

## Issue 2 (Important): `SectionReconciler` is NOT Sendable-compatible

**Plan reference:** Step 3 (lines 146-177)

The plan states: "Make `SectionReconciler` Sendable -- it should already be stateless (verify)"

Verification result from `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Services/SectionReconciler.swift`:
- `SectionReconciler` is declared as `class SectionReconciler` (a reference type, no conformance to Sendable)
- It IS stateless -- all methods only operate on parameters, no stored properties
- But it is NOT marked Sendable, and Swift strict concurrency will flag it when captured in a `Task.detached`

**The fix is straightforward:** Either mark it `final class SectionReconciler: Sendable` (it has no mutable state, so this is correct), OR change the `reconcile()` call to a static method. The plan should be explicit about which approach to take.

Additionally, `parseHeaders()` is currently an *instance method* on `SectionSyncService` (defined in `SectionSyncService+Parsing.swift` line 17). It accesses `ExportSettingsManager.shared` (a @MainActor-isolated singleton) inside the method body (line 48). Making this a static/nonisolated function requires handling that `@MainActor` dependency. The plan says "extract as static" but doesn't address the `ExportSettingsManager.shared` access.

**Recommendation:** Capture `ExportSettingsManager.shared.bibliographyHeaderName` on the main thread before dispatching, and pass it as a parameter. The plan's Step 3 code example already captures `isZoomed` but needs to also capture `bibHeaderName` and `notesHeaderName`.

**Severity:** Important -- will cause compile errors in strict concurrency without these adjustments.

---

## Issue 3 (Important): Block sync plugin `apply()` debounce has a stale-`newState` closure capture problem

**Plan reference:** Step 5 (lines 193-210)

The plan proposes:

```js
apply(tr, value, _oldState, newState) {
    if (!tr.docChanged || syncPaused) return value;
    if (changeDetectionTimer) clearTimeout(changeDetectionTimer);
    changeDetectionTimer = setTimeout(() => {
        const newSnapshot = snapshotBlocks(newState.doc);
        detectChanges(currentState.lastSnapshot, newSnapshot, currentState);
        currentState.lastSnapshot = newSnapshot;
    }, 100);
    return value;
}
```

**The problem:** `newState` is captured in the setTimeout closure. If multiple transactions fire within the 100ms debounce window, only the *first* transaction's `newState` is captured (the timer is cleared and recreated with each new transaction, but each closure captures the `newState` from its own invocation). Actually wait -- the timer IS cleared and recreated, so the final closure will capture the final `newState`. This is correct.

However, there is a different problem: the `value` returned is never updated. The `apply()` function returns the *same* plugin state value without updating `lastSnapshot`. So `value.lastSnapshot` remains stale across all transactions during the debounce window. When the debounce finally fires, it compares `currentState.lastSnapshot` (still the pre-debounce snapshot) against the latest doc -- this is actually correct for detecting cumulative changes.

BUT: the `apply()` method also needs to return an updated value to ProseMirror's plugin state system. Currently it returns the old `value` unchanged, which means `currentState` is also not updated (line 347 in actual code: `currentState = newValue`). The plan's version doesn't update `currentState` in `apply()`, which means `currentState.lastSnapshot` stays frozen during the debounce window. When the timeout fires, `detectChanges(currentState.lastSnapshot, newSnapshot, currentState)` compares the pre-debounce snapshot against the final doc -- this correctly detects all cumulative changes. So the logic IS correct, but it means intermediate states are invisible (e.g., a block that was inserted and then deleted within the 100ms window would be missed). For a 100ms window this is acceptable.

**Revised assessment:** The logic is actually correct for cumulative change detection. No issue here.

**However**, there is a real concern: `snapshotBlocks()` calls `getAllBlockIds()` (line 221 in block-sync-plugin.ts), which reads from the block-id-plugin's `currentBlockIds` map. If block-id-plugin's `assignBlockIds()` is ALSO debounced (as proposed in Step 5 for block-id-plugin), then `snapshotBlocks()` may read stale block IDs from the block-id-plugin when the block-sync debounce fires. The plan proposes these share the same timer, but that needs to be explicit: **block ID assignment must complete BEFORE block sync snapshot runs**. If they share a timer, the execution order within the single callback must be: (1) assignBlockIds, (2) snapshotBlocks + detectChanges.

**Severity:** Important -- if the shared timer doesn't enforce this ordering, block sync will snapshot with stale IDs, potentially generating spurious insert/delete pairs.

---

## Clarification 1: `SectionSyncService.syncContent()` read-then-write pattern with DatabasePool

**Plan reference:** Step 2 (lines 117-140)

The plan notes: "Verify no code depends on read-after-write consistency across separate read{}/write{} calls"

The `syncContent()` method in `SectionSyncService.swift` (lines 191-246) performs:
1. `db.fetchSections(projectId:)` -- uses `read {}`
2. Reconcile in memory
3. `db.applySectionChanges()` -- uses `write {}`
4. `db.saveContent()` -- uses `write {}`

With `DatabasePool`, a concurrent write between steps 1 and 3 could cause the reconciliation to operate on stale data. However, section sync is debounced at 500ms and runs sequentially (the debounce task awaits completion). The only other writer to sections is drag-drop reordering, which sets `isSyncSuppressed = true` to prevent concurrent sync. So in practice, there is no concurrent writer to sections.

For blocks, `BlockSyncService.applyChanges()` (line 258-265) calls `database.applyBlockChangesFromEditor()` which is a single `write {}` transaction. The `fetchBlocks` + `write` pattern exists in `ContentView+SectionManagement.swift` and zoom operations, but these are user-initiated actions that suppress sync. So this is safe.

**Verdict:** No issue. The existing synchronization guards (debounce, suppression flags) prevent problematic concurrent access.

---

## Clarification 2: Milkdown `getMarkdown()` interaction with ProseMirror transaction batching

**Plan reference:** Step 1, question about 50ms debounce vs ProseMirror batching

ProseMirror does not batch transactions -- each `view.dispatch(tr)` is synchronous and immediate. The 50ms debounce in the plan is applied *after* `originalDispatch(tr)` completes, so it does not interfere with ProseMirror's internal state management. The `getIsSettingContent()` guard (line 198 of actual main.ts) correctly prevents the debounce from firing during programmatic content setting. The plan's approach of deferring `getMarkdown()` to the debounce callback is sound -- it means `setCurrentContent()` is also deferred, but since the polling will be demoted to 3s fallback, there's no correctness issue (the push message delivers content directly).

**Verdict:** No issue.

---

## Items correctly addressed (no further action needed)

1. **Handler registration locations (Step 1):** The plan identifies 4 registration points. Verified against actual code:
   - `MilkdownEditor.swift` lines 48-57 (preloaded path) and lines 112-120 (fallback path) -- correct
   - `CodeMirrorEditor.swift` lines 43-50 (preloaded path) and lines 103-109 (fallback path) -- correct

2. **"First in chain" placement (Step 1):** The plan places `contentChanged` handler first in `userContentController(_:didReceive:)`. Currently the first check is `errorHandler` (line 198 of MilkdownCoordinator+MessageHandlers.swift). Adding `contentChanged` before it is correct since it fires most frequently.

3. **Grace period reduction (Step 1):** Milkdown currently uses 600ms (line 675), plan reduces to 200ms. CodeMirror uses 300ms (line 668), plan reduces to 150ms. Both reductions are appropriate for push-based flow.

4. **DatabasePool as drop-in (Step 2):** `dbWriter` is typed as `any DatabaseWriter & Sendable` (line 10 of ProjectDatabase.swift). `DatabasePool` conforms to both protocols. The `read {}` and `write {}` convenience methods (lines 316-322) forward to `dbWriter`, so they work with either.

5. **BlockSyncService polling (Step 4):** Changing from 0.3 to 2.0 seconds is safe because changes accumulate in JS-side pending maps.

6. **Focus mode optimization (Step 6):** The two-pass `doc.descendants()` pattern is confirmed at lines 38-47 and 50-60 of `focus-mode-plugin.ts`. Merging into a single pass is straightforward.

7. **`.removeDuplicates()` on outline observation (Step 7):** Confirmed missing at line 43-54 of `Database+BlocksObservation.swift`. `observeBlocks()` has it (line 24) but `observeOutlineBlocks()` does not.

---

## Recommended plan amendments

1. **Step 1 (CodeMirror):** Change the debounce closure to use `getEditorView()` from module state rather than the closure-captured `update.view`.

2. **Step 3:** Add explicit note that `SectionReconciler` needs `final class SectionReconciler: Sendable` annotation. Add note that `parseHeaders()` requires capturing `ExportSettingsManager.shared.bibliographyHeaderName` on MainActor before dispatching, since `ExportSettingsManager.shared` is @MainActor-isolated.

3. **Step 5:** Specify that the shared debounce timer for block-id and block-sync must execute in order: `assignBlockIds()` first, then `snapshotBlocks()` + `detectChanges()`. Suggest a single callback that chains both operations.
