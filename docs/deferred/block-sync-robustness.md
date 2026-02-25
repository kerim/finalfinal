# Block Sync Robustness: Deferred Issues

Issues identified during Phase 2 block sync code review. These don't cause the "new content gets deleted" bug (which is JS-side change detection), but are adjacent sync correctness risks.

## 1. Float Precision Exhaustion in Sort Order Midpoints (CRITICAL — theoretical)
**File:** `Database+Blocks.swift:421`

`sortOrder = (afterBlock.sortOrder + next.sortOrder) / 2.0` — after ~52 successive bisections between two blocks, Double precision is exhausted. `normalizeSortOrders()` exists but is only called during initialization, not proactively during inserts.

**Fix:** Add proactive normalization when `|afterBlock.sortOrder - next.sortOrder| < 1e-10`, or call `normalizeSortOrders` after each insert batch.

## 2. Mass Delete Safety Net Causes Permanent Desync (IMPORTANT)
**File:** `Database+Blocks.swift:312-319`

When safety net rejects deletes, JS editor thinks blocks were deleted but DB retains them. No error or resync signal is sent back. Blocks will reappear on next `rebuildDocumentContent`.

**Fix:** Return a signal to `BlockSyncService` when deletes are rejected, triggering a full resync (`pushBlockIds` + `setContentWithBlockIds`).

## 3. 100ms Sleep Before pushBlockIds is Fragile (IMPORTANT)
**Files:** `ContentView.swift:552,1261`

Fixed sleep used to "wait for WebView to process content" after hierarchy enforcement. Should use acknowledgement pattern (`waitForContentAcknowledgement`) instead.

## 4. isSyncSuppressed Cleared Too Early by Defer (IMPORTANT)
**File:** `BlockSyncService.swift:78-79`

`defer { isSyncSuppressed = false }` clears the flag when `pushBlockIds` returns, but the editor's ProseMirror transaction from `syncBlockIds` may not have settled yet. Next poll can read transitional state.

**Fix:** Use a completion callback or acknowledgement from JS side before clearing suppression.

## 5. Non-Atomic Two-Step JS Check (checkForChanges + getBlockChanges) (IMPORTANT)
**File:** `BlockSyncService.swift:174-178`

Two separate `evaluateJavaScript` calls with no atomicity. Changes could accumulate between calls.

**Fix:** Combine into single `getBlockChangesIfAny()` call.

## 6. Timer-Based Polling Can Drop Cycles (IMPORTANT)
**File:** `BlockSyncService.swift:48-52`

Timer fires create unstructured Tasks. If a poll takes >300ms, the `isPolling` guard drops the cycle silently. Content changes during slow polls are delayed until the next cycle.

**Fix:** Use `Task.sleep`-based loop instead of Timer for natural serialization.
