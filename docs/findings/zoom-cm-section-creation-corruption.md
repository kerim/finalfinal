# Zoom + CodeMirror Section Creation Corruption

## Summary

When zoomed into a section in CodeMirror, adding new headings (especially at a higher level than the zoom target) caused severely corrupted content on zoom-out: duplicated sections, wrong heading levels, and content appearing multiple times. The section count in the DB grew unboundedly (18 -> 20 -> 22 -> 24 -> 26 -> 28) during zoomed editing. Four interacting root causes created a feedback loop. Fixed with five surgical changes.

## Reproduction Steps

1. Create a document with multiple sections (h1, h2, h3, h4)
2. Switch to CodeMirror (Cmd+/)
3. Double-click "## one point two" to zoom in
4. Add `### test sub-section h3` with body text
5. Add `# test super-section h1` with body text
6. Wait 2 seconds for sync
7. Click breadcrumb to zoom out
8. Observe: duplicated sections, wrong heading levels, unbounded section count growth

## Root Cause Analysis

Four interacting issues created a feedback loop:

### 1. Hierarchy enforcement during zoom triggers feedback loop

User adds headings -> DB observation fires -> `onSectionsUpdated` -> enforcement modifies heading levels -> rebuilds content -> content change triggers block reparse -> new DB writes -> observation fires again -> loop continues.

### 2. Zoom range boundary shrinks incorrectly

After `replaceBlocksInRange`, the range was recalculated using level-based logic: "find next heading at level <= zoomed heading." Adding an h1 while zoomed into h2 caused the range end to move to the h1 (because h1 <= h2), excluding it from the zoomed view. The h1 persisted in DB but was filtered out, then re-created on the next flush -> duplication.

### 3. `zoomedSectionIds` never updated during zoom

`filterBlocksForZoomStatic` relied on ID-based matching, but new sections created during zoom had new IDs not in the `zoomedSectionIds` set. These sections were filtered out of zoom view but persisted in DB, causing desync.

### 4. `sourceContent` desync

`rebuildDocumentContentStatic` updated `content` but not `sourceContent`. CodeMirror still showed old text and re-sent it, creating duplicate blocks.

## Fixes Applied

### Fix 1: Skip hierarchy enforcement while zoomed

**File:** `ContentView+ProjectLifecycle.swift`

Added `guard editorState.zoomedSectionIds == nil else { return }` before the violation check in `onSectionsUpdated`. This breaks the feedback loop. After zoom-out, `zoomedSectionIds` is nil, so enforcement resumes naturally. Also removed dead code (block-ID push logic that became unreachable with the guard).

### Fix 2: Count-based zoom range boundary

**File:** `EditorViewState+Zoom.swift`

Replaced level-based range recalculation in `flushCodeMirrorSyncIfNeeded()` with count-based approach: `newEnd = newStart + Double(blocks.count)`. This prevents higher-level headings from shrinking the range. The heading's new `sortOrder` tracks its position; the end boundary is the first block after all inserted blocks.

### Fix 3: Range-based zoom filtering

**File:** `ContentView+ContentRebuilding.swift`, `ContentView+HierarchyEnforcement.swift`

Added `zoomedBlockRange` parameter to `filterBlocksForZoomStatic`. When a range is available, filtering uses sort-order bounds instead of ID matching. This automatically includes new blocks created during zoom. Falls back to existing ID-based filtering when range is nil.

### Fix 4: sourceContent sync in rebuildDocumentContentStatic

**File:** `ContentView+HierarchyEnforcement.swift`

After setting `editorState.content`, also update `sourceContent` when in source mode. Uses the same anchor injection pattern as `updateSourceContentIfNeeded()`, including the trailing newline offset adjustment.

### Fix 5: Post-zoom-out hierarchy enforcement

**File:** `ContentView.swift`

Added deferred hierarchy enforcement in the `.didZoomOut` handler. Since Fix 1 skips enforcement during zoom, this catches accumulated violations immediately after zoom-out. Guarded by `contentState == .idle` to avoid redundant passes.

## Files Modified

| File | Fixes | Changes |
|------|-------|---------|
| `Views/ContentView+ProjectLifecycle.swift` | 1 | Zoom guard + dead code removal in `onSectionsUpdated` |
| `ViewState/EditorViewState+Zoom.swift` | 2 | Count-based range recalculation in `flushCodeMirrorSyncIfNeeded` |
| `Views/ContentView+ContentRebuilding.swift` | 3 | Range param on `filterBlocksForZoomStatic` + instance wrapper + caller update |
| `Views/ContentView+HierarchyEnforcement.swift` | 3, 4 | Filter caller update + sourceContent sync in `rebuildDocumentContentStatic` |
| `Views/ContentView.swift` | 5 | Hierarchy enforcement in `.didZoomOut` handler |

## Architectural Patterns Established

**Defer enforcement during partial-view edits:** When editing in a filtered context (zoom), skip constraints that assume full-document visibility. Enforce them when the full context is restored (zoom-out). This prevents feedback loops where the enforcement itself triggers further changes.

**Count-based range boundaries over level-based:** When tracking the range of blocks that belong to a zoomed section, use the count of inserted blocks to determine the end boundary, not heading-level scanning. Level-based scanning breaks when the user creates headings at higher levels than the zoom target.

**Range-based filtering over ID-based during zoom:** Sort-order range filtering automatically includes newly created blocks. ID-based filtering fails for blocks created during zoom because their IDs aren't in the pre-computed `zoomedSectionIds` set.

**Always sync both content properties:** When `content` is updated programmatically, `sourceContent` must also be updated if in source mode. Otherwise CodeMirror continues showing stale text and re-sends it on the next change.

---

## Regression: Sort-Order Collision on Zoom-Out

### Summary

After the five fixes above, a new regression appeared: zooming out after creating headings in a zoomed CodeMirror view produced duplicate headings. The root cause was a sort-order collision in `replaceBlocksInRange()` — a direct consequence of Fix 2's count-based range boundary.

### Root Cause

Fix 2 changed the zoom range end boundary from level-based scanning to `newEnd = newStart + Double(blocks.count)`. This correctly prevented higher-level headings from shrinking the range, but created a new problem: when the user adds headings during zoom, the number of blocks being inserted (N) can exceed the number of blocks originally in the range (M). The inserted blocks' sort orders (`startSortOrder + 0`, `startSortOrder + 1`, ..., `startSortOrder + N-1`) overflow past `endSortOrder`, colliding with blocks that follow the range.

Example: Range `[3.0, 5.0)` holds 2 blocks. User adds headings, producing 4 blocks. Blocks get sort orders 3.0, 4.0, 5.0, 6.0 — but blocks at 5.0 and 6.0 already exist outside the range. The collisions cause duplicate sections on zoom-out.

### Fix: Shift Blocks After Range (Step 2.5)

**File:** `Models/Database+BlocksReorder.swift`

Added step 2.5 in `replaceBlocksInRange()`, between deleting old blocks (step 2) and inserting new blocks (step 3). When the inserted block count overflows the original range, shift all blocks at or after `endSortOrder` forward by the overflow amount:

```swift
// 2.5. Shift blocks after range to prevent sort order collisions
if let end = endSortOrder {
    let insertEnd = startSortOrder + Double(newBlocks.count)
    if insertEnd > end {
        let shift = insertEnd - end
        try db.execute(
            sql: """
                UPDATE block SET sortOrder = sortOrder + ?, updatedAt = ?
                WHERE projectId = ? AND sortOrder >= ?
                """,
            arguments: [shift, Date(), projectId, end]
        )
    }
}
```

This preserves the relative ordering of all blocks outside the range while making room for the larger insert.
