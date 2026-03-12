# Image Block Duplication from Content Push Debounce Race

Branch: `slowdown`. Regression from increasing content push debounce 50ms→300ms.

---

## Problem

Opening the getting-started document spawned thousands of duplicate image blocks (3352 blocks, expected ~100). The document became unusable.

## Root Cause

The 300ms content push debounce in `main.ts` created a stale timer race condition during document load:

1. Editor initializes → normalization transactions fire → 300ms `contentPushTimer` is set
2. Within 300ms, Swift calls `setContentWithBlockIds()` → replaces doc, assigns block IDs → clears `isSettingContent` and sets `contentHasBeenSet`
3. At 300ms, the stale timer fires. Both `isSettingContent` (false) and `contentHasBeenSet` (true) guards pass. It serializes the doc and sends `contentChanged` to Swift
4. Swift's `handleContentPush()` has a 200ms grace period from `lastPushTime`, but 300ms > 200ms so the push is accepted. The `lastPushedContent` equality check fails for image-containing documents because markdown serialization loses figure node attributes (`blockId`, `width`)
5. Swift updates `contentBinding` → `updateNSView()` → `setContent()` → doc replaced again
6. Each `setContent()` re-parses → figure nodes get new node references → `assignBlockIds()` fails proximity matching → figure gets `temp-` ID → INSERT into database
7. 300ms later, another stale timer fires → cascade repeats

With 50ms the window was too narrow for the race to trigger reliably, but it was a probabilistic fix, not a structural one.

## Fix (4 layers)

### 1. Revert debounce to 50ms (immediate)

`main.ts` timer reverted from 300ms to 50ms.

### 2. Shared timer state + clearing (structural)

The `contentPushTimer` was a local variable inside `initEditor()` — inaccessible to `api-content.ts` (circular dependency prevents importing from `main.ts`).

**Solution:** Moved timer state to `editor-state.ts` (leaf module, no intra-project imports). Added `setContentPushTimer()` and `clearContentPushTimer()` exports. `api-content.ts` calls `clearContentPushTimer()` at the top of `setContent()`, `setContentWithBlockIds()`, `applyBlocks()`, and `resetForProjectSwitch()`.

This ensures any programmatic document replacement cancels stale timers. The debounce can be safely increased in the future.

### 3. Adjacent image dedup on load (cleanup)

`Database+Blocks.swift` added `deduplicateAdjacentImageBlocks(projectId:)` — finds image blocks with identical `markdownFragment` that are consecutive by sort order, keeps the first, deletes the rest. Called in `configureForCurrentProject()` after `normalizeSortOrders()`, before `startObserving()`.

Only deduplicates **adjacent** blocks to avoid destroying legitimately repeated images in different chapters.

### 4. Within-batch INSERT dedup guard (defense in depth)

In `applyBlockChangesFromEditor()`, a local `insertedImageFragments` dictionary tracks which image fragments have been inserted in the current batch. If a duplicate is found, the temp ID is mapped to the first-inserted block's permanent ID and the duplicate insert is skipped.

## Files Modified

- `web/milkdown/src/editor-state.ts` — `contentPushTimer` state + getter/setter
- `web/milkdown/src/main.ts` — use shared timer, revert to 50ms
- `web/milkdown/src/api-content.ts` — `clearContentPushTimer()` in 4 functions
- `final final/Models/Database+Blocks.swift` — `deduplicateAdjacentImageBlocks()` + batch dedup guard
- `final final/Views/ContentView+ProjectLifecycle.swift` — call dedup on project load

## Lesson

Content push debounce timing interacts non-obviously with the Swift→JS→Swift content round-trip. The structural fix (timer clearing) decouples the two: programmatic content pushes cancel any pending user-initiated timer, regardless of debounce duration. Any future debounce changes should be paired with testing of image-heavy documents at load time.
