# Round 3 Review: Typing Latency Fix Plan

## Overall Verdict

The plan is solid after two rounds of refinement. The major architectural decisions (push-based messaging, DatabasePool, off-main DB writes, debounced block-sync detection) are all sound and well-reasoned. The previous rounds caught the most dangerous issues (ProseMirror immutability, blockIdPlugin debounce, isSettingContent re-check, MainActor isolation).

I found **one important issue** and **two minor suggestions**. The plan is ready for implementation after addressing the important issue.

---

## Issue 1: IMPORTANT -- `DocumentManager.shared.checkGettingStartedEdited()` is `@MainActor` and called after `Task.detached`

**File:** `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Services/SectionSyncService.swift` line 242

**Problem:** In the plan's Step 3c refactored `syncContent()`, the code shows this pattern:

```swift
// Back on MainActor
lastSyncedContent = markdown
DocumentManager.shared.checkGettingStartedEdited(currentMarkdown: markdown)
```

This is placed **after** the `try await Task.detached { ... }.value` call, which correctly means it runs back on MainActor (since the enclosing function is `@MainActor`). This part is fine.

However, the plan does **not** mention that `DocumentManager.shared` is itself `@MainActor @Observable` (verified at `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Services/DocumentManager.swift` line 13-15). The plan's code snippet would work correctly because the `await` on `.value` returns to MainActor context. But this should be explicitly noted in the plan to prevent a future implementor from accidentally moving this call inside the detached task.

**Verdict:** Not actually broken -- the plan's code is correct as written. The `await Task.detached { }.value` pattern properly suspends the MainActor function and resumes on MainActor after completion. This is a documentation/clarity note, not a bug.

---

## Issue 2: IMPORTANT -- Step 5 timing hazard with rapid keystrokes and `capturedOldSnapshot`

**File:** `/Users/niyaro/Documents/Code/ff-dev/typing-delay/web/milkdown/src/block-sync-plugin.ts`

**The plan proposes:**

```js
apply(tr, value, _oldState, newState) {
    if (!tr.docChanged || syncPaused) return value;
    const newSnapshot = snapshotBlocks(newState.doc);
    if (detectTimer) clearTimeout(detectTimer);
    const capturedOldSnapshot = value.lastSnapshot;
    detectTimer = setTimeout(() => {
        detectChanges(capturedOldSnapshot, newSnapshot, currentState);
    }, 100);
    const newValue = { ...value, lastSnapshot: newSnapshot };
    currentState = newValue;
    return newValue;
}
```

**The concern:** Consider rapid typing: keystroke A fires `apply()`, captures `capturedOldSnapshot = snapshot_0`, schedules detectChanges(snapshot_0, snapshot_A). Then keystroke B fires before the 100ms timer, clears the timer, captures `capturedOldSnapshot = value.lastSnapshot` which is now `snapshot_A` (set by the previous return), and schedules detectChanges(snapshot_A, snapshot_B). This is correct -- the debounce naturally coalesces by always using the latest pair.

But wait: the timeout fires with `currentState` captured by closure reference (not by value). By the time detectChanges runs, `currentState` might have been replaced by a newer return value. The `detectChanges` function writes to `state.pendingUpdates`, `state.pendingInserts`, `state.pendingDeletes`. If `currentState` has already been replaced, the writes go to an object that is no longer the plugin's active state.

**Analysis of actual impact:** Looking at the current code at line 73: `let currentState: BlockSyncPluginState | null = null;` -- this is a module-level variable. And at line 347: `currentState = newValue;` -- this is updated on every `apply()`. The debounced `detectChanges()` call passes `currentState` which is the module-level reference. By the time the callback fires, `currentState` points to the most recent plugin state, which IS the correct one to mutate (it's the same object that `getBlockChanges()` and `hasPendingChanges()` read from).

But there's a subtlety: when keystroke B clears the timer and sets a new one, the `capturedOldSnapshot` for the new timer is `snapshot_A`, and `newSnapshot` is `snapshot_B`. The timer from keystroke A (snapshot_0 -> snapshot_A) is cancelled. So `detectChanges(snapshot_A, snapshot_B)` only sees the diff between A and B, missing the diff between 0 and A.

**This is actually a problem.** If keystroke A inserted a new block and keystroke B edited text within it, the debounce would skip the insert detection from A and only see the update from B. The block insert would be lost.

**Fix:** The `capturedOldSnapshot` should capture the **oldest un-processed** snapshot, not the immediately preceding one. When the timer is cleared without firing, the old snapshot from the cancelled timer should be preserved:

```js
let pendingOldSnapshot: Map<string, BlockSnapshot> | null = null;
let detectTimer: ReturnType<typeof setTimeout> | null = null;

apply(tr, value, _oldState, newState) {
    if (!tr.docChanged || syncPaused) return value;
    const newSnapshot = snapshotBlocks(newState.doc);

    // Preserve the oldest un-processed snapshot across debounce resets
    if (detectTimer) {
        clearTimeout(detectTimer);
        // Keep the existing pendingOldSnapshot (from the first keystroke)
    } else {
        // First keystroke in this debounce window
        pendingOldSnapshot = value.lastSnapshot;
    }

    const capturedOld = pendingOldSnapshot!;
    detectTimer = setTimeout(() => {
        detectChanges(capturedOld, newSnapshot, currentState!);
        pendingOldSnapshot = null;
        detectTimer = null;
    }, 100);

    const newValue = { ...value, lastSnapshot: newSnapshot };
    currentState = newValue;
    return newValue;
}
```

This ensures that after rapid keystrokes A, B, C within 100ms, the final `detectChanges()` compares `snapshot_0` (before A) against `snapshot_C` (after C), catching all inserts, updates, and deletes across the entire burst.

---

## Issue 3: Suggestion -- Step 3d `syncZoomedSections()` captures are incomplete

**File:** `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Services/SectionSyncService.swift` lines 251-380

The plan says "Apply same treatment to `syncZoomedSections()`" but doesn't provide a code sketch. Looking at the actual method, it calls:
- `db.fetchSections()` -- can move off-main
- `Self.stripZoomNotes()` -- static, fine
- `parseHeaders()` -- needs `fallbackBibTitle` capture (same as 3c)
- `syncMiniNotesBack()` -- does its own DB read/write, needs same treatment
- `db.applySectionChanges()` -- can move off-main
- `onZoomedSectionsUpdated?(updatedZoomedIds)` -- this is a callback, likely needs MainActor

The method also accesses `self.reconciler` implicitly through closure. Since the plan converts `SectionReconciler` to a `Sendable struct`, that's fine.

The tricky part is `onZoomedSectionsUpdated?()` -- this callback presumably updates UI state and needs to remain on MainActor. This should be called back on MainActor after the detached task, similar to how `lastSyncedContent` is updated in 3c.

**Recommendation:** Add a brief note that `onZoomedSectionsUpdated?()` must remain on MainActor (after the `.value` await), not inside the detached task.

---

## Verification of Specific Plan Items

### Step 1 -- CodeMirror `isSettingContent` (VERIFIED CORRECT)

The plan states: "CodeMirror has no JS-side `isSettingContent` flag -- the Swift-side grace period guard is the protection against echoes."

**Confirmed.** I read `/Users/niyaro/Documents/Code/ff-dev/typing-delay/web/codemirror/src/editor-state.ts` in full (117 lines). There is no `isSettingContent` variable or getter. The Milkdown side has it in `web/milkdown/src/editor-state.ts` at line 8-32, but CodeMirror does not.

The plan correctly relies on the Swift-side grace period (150ms) for CodeMirror echo prevention. This is adequate because:
1. CodeMirror's `setContent()` (`api.ts` line 98-149) dispatches synchronously via `view.dispatch()`
2. The `updateListener` would see this as `docChanged` and fire the push timer
3. The 50ms debounce timer would then fire, and the Swift grace period (150ms) would reject it

One subtlety: the CodeMirror `setContent()` has a `requestAnimationFrame` at line 111 and potentially a double-RAF at line 130 for zoom transitions. These don't affect the `doc.toString()` which is read synchronously. The grace period is sufficient.

### Step 3 -- `parseHeaders()` and `ExportSettingsManager.shared.bibliographyHeaderName` (VERIFIED CORRECT)

**Confirmed.** At `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Services/SectionSyncService+Parsing.swift` line 46:
```swift
let bibHeaderName = existingBibTitle ?? ExportSettingsManager.shared.bibliographyHeaderName
```

And `ExportSettingsManager` is `@MainActor @Observable` (confirmed at `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Models/ExportSettings.swift` line 146-148). The plan correctly identifies this dependency and proposes capturing `fallbackBibTitle` on MainActor before the detached task, passing it as a parameter to a static `parseHeaders()`.

### Step 3a -- `SectionReconciler` class->struct (VERIFIED CORRECT)

**Confirmed.** At `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Services/SectionReconciler.swift` line 27: `class SectionReconciler` has zero stored properties. All methods are pure functions operating on parameters. Converting to `struct SectionReconciler: Sendable` is a safe, drop-in change.

### Step 3b -- `parseHeaders()` can be static (VERIFIED CORRECT)

**Confirmed.** The method at `SectionSyncService+Parsing.swift` line 17 is an instance method but accesses no instance state (only local variables and the `ExportSettingsManager.shared` global). Making it `static` with the `fallbackBibTitle` parameter is correct. Same for `parseHeaderLine()` (line 202), `extractPseudoSectionTitle()` (line 225), and `extractExcerpt()` (line 265) -- all pure functions.

### Step 3e -- `BlockChanges` Sendable (VERIFIED CORRECT)

**Confirmed.** At `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Models/Block.swift`:
- `BlockChanges: Codable, Sendable` (line 335)
- `BlockUpdate: Codable, Sendable` (line 327)
- `BlockInsert: Codable, Sendable` (line 317)

All types are already `Sendable`.

### Step 5 -- ProseMirror immutability (VERIFIED CORRECT)

The plan correctly keeps `snapshotBlocks()` synchronous in `apply()` and returns a proper new state object with the spread operator. The `value` object is never mutated. The `detectChanges()` function writes to `currentState`'s pending maps, which is the module-level reference (not the immutable plugin state). This is fine because pending changes are external bookkeeping, not part of ProseMirror's state contract.

### Step 5 -- redundant `nodeToMarkdownFragment()` (VERIFIED)

At line 280 in `block-sync-plugin.ts`:
```typescript
markdownFragment: nodeToMarkdownFragment(newBlock.node),
```

The plan correctly notes that `newBlock.markdownFragment` is already computed in `snapshotBlocks()` at line 243. Changing this to `newBlock.markdownFragment` avoids redundant serialization. Confirmed correct.

### Step 6 -- Focus mode two-pass walk (VERIFIED CORRECT)

At `/Users/niyaro/Documents/Code/ff-dev/typing-delay/web/milkdown/src/focus-mode-plugin.ts` lines 38-62, there are indeed two separate `doc.descendants()` calls. The plan's single-pass approach is correct and equivalent.

Minor note: the current code at line 41 uses `currentPos <= nodeEnd` while the plan uses `currentPos < nodeEnd`. The plan's strict `<` is technically more correct since `nodeEnd` is `pos + node.nodeSize`, which is one past the last position. When cursor is at `nodeEnd`, it's actually at the start of the next node. The plan's version is a slight behavioral improvement.

### Step 7 -- `observeOutlineBlocks()` missing `.removeDuplicates()` (VERIFIED CORRECT)

At `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Models/Database+BlocksObservation.swift`:
- `observeBlocks()` (line 17) has `.removeDuplicates()` at line 24
- `observeOutlineBlocks()` (line 43) does NOT have `.removeDuplicates()`

The plan correctly identifies this omission.

### Step 2 -- DatabasePool migration (VERIFIED CORRECT)

At `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Models/ProjectDatabase.swift` line 15:
```swift
self.dbWriter = try DatabaseQueue(path: package.databaseURL.path)
```

The `dbWriter` type is `any DatabaseWriter & Sendable` (line 10), so `DatabasePool` is indeed a drop-in replacement. The plan's note about WAL migration on first open is correct per GRDB documentation.

---

## Summary

| # | Severity | Issue | Status |
|---|----------|-------|--------|
| 1 | Suggestion | Document that `DocumentManager.shared.checkGettingStartedEdited()` is @MainActor | Plan code is correct, add comment |
| 2 | **Important** | Step 5 debounce loses changes between cancelled timers -- must preserve oldest un-processed snapshot | Needs fix |
| 3 | Suggestion | Step 3d -- note `onZoomedSectionsUpdated?()` must stay on MainActor | Add note to plan |

The plan is well-constructed and ready for implementation after fixing Issue 2. The previous two review rounds successfully caught the most critical problems (ProseMirror state immutability, blockIdPlugin debounce prohibition, isSettingContent re-check, MainActor isolation of ExportSettingsManager). The remaining issue is a timing edge case in the debounce logic that would cause missed block inserts/deletes during rapid typing bursts.
