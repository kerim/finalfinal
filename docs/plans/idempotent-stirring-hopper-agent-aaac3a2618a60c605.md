# Code Review: Editor Switch Content Corruption Fix

## Plan Reference
Plan file: `/Users/niyaro/Documents/Code/ff-dev/images/docs/plans/idempotent-stirring-hopper.md`

---

## 1. Diagnosis Verification

### 1a. Does the TO-source-mode path skip flushing? -- CONFIRMED (HIGH confidence)

In `/Users/niyaro/Documents/Code/ff-dev/images/final final/Views/ViewNotificationModifiers.swift`, lines 43-100, the WYSIWYG-to-source switch path does the following:

1. Sets `contentState = .editorTransition` (line 45)
2. Determines which sections to inject anchors for (lines 48-53)
3. Immediately fetches blocks from DB via `db.fetchBlocks(projectId: pid)` (lines 62/67)
4. Computes character offsets from those blocks (lines 69-85)
5. Injects anchors at computed offsets (lines 89-97)

There is no `flushContentToDatabase()` call anywhere in this path. The blocks table is read directly without ensuring it reflects the current editor content.

### 1b. Does the FROM-source-mode path flush? -- CONFIRMED (HIGH confidence)

In the same file, lines 101-123, the source-to-WYSIWYG switch path does:

1. Sets `contentState = .editorTransition` (line 103)
2. **Calls `editorState.flushContentToDatabase()`** (line 104)
3. Then proceeds with anchor extraction (lines 107-112)

This is a clear asymmetry. The plan correctly identifies that the reverse direction already has the flush but the forward direction does not.

### 1c. Could stale blocks produce wrong offsets? -- CONFIRMED (HIGH confidence)

The offset computation (lines 69-85) works as follows:

```swift
var offset = 0
for (i, block) in sorted.enumerated() {
    if i > 0 { offset += 2 }  // "\n\n" separator
    blockOffset[block.id] = offset
    offset += block.markdownFragment.count
}
```

Each block's character offset is cumulative -- it depends on the `markdownFragment.count` of ALL preceding blocks. If an image block (e.g., `![alt](media/image.png)`) is missing from the blocks table because BlockSyncService hasn't polled yet, then:

- The total character count from blocks will be SHORT by the image markdown length
- All section anchor offsets computed after the image's position will be WRONG
- The `injectSectionAnchors` call on line 89-92 will inject `<!-- @sid:UUID -->` at incorrect positions in `editorState.content`, which DOES contain the image markdown
- This corrupts paragraph boundaries, leading to the reported symptoms: merged headings, lost text

The mismatch between `editorState.content` (which has the image) and `db.fetchBlocks()` (which does not) is the root cause.

---

## 2. Fix Verification

### 2a. Will `flushContentToDatabase()` at the proposed position correctly update the blocks table? -- YES (HIGH confidence)

The plan proposes adding `editorState.flushContentToDatabase()` after line 45 (after `contentState = .editorTransition`), before the offset computation at line 55.

Looking at `flushContentToDatabase()` in `/Users/niyaro/Documents/Code/ff-dev/images/final final/ViewState/EditorViewState+Zoom.swift` (line 348-423):

1. It reads `content` (which is `editorState.content` -- already up-to-date from Milkdown polling/push)
2. Fetches existing blocks to preserve metadata (line 358)
3. Calls `BlockParser.parse(markdown: contentToParse, projectId: pid, ...)` (lines 371-375)
4. Writes parsed blocks via `db.replaceBlocks()` or `db.replaceBlocksInRange()` (lines 378-418)

After this call, the blocks table will accurately reflect the editor content, including any recently-inserted image markdown. The subsequent `db.fetchBlocks()` call will return correct data.

### 2b. Timing/race issues? -- NONE DETECTED (HIGH confidence)

`flushContentToDatabase()` is synchronous (no `await`). It runs entirely on the `@MainActor` (both the calling code in `ViewNotificationModifiers` and `EditorViewState` are `@MainActor`). The GRDB database writes via `dbQueue.write` are synchronous within the function body. By the time `flushContentToDatabase()` returns, the blocks table is fully updated and the next `db.fetchBlocks()` call will see the new data.

The function also cancels any pending `blockReparseTask` (line 353-354), preventing a later debounced reparse from interfering.

### 2c. Does zoomed-mode path in `flushContentToDatabase()` handle correctly? -- YES (HIGH confidence)

`flushContentToDatabase()` checks `zoomedBlockRange` (line 377):
- If zoomed: uses `db.replaceBlocksInRange()` to only replace blocks within the zoom scope
- If not zoomed: uses `db.replaceBlocks()` for full document replacement

When switching editors, the user could be zoomed or not. Both paths are handled. The WYSIWYG-to-source switch code (lines 48-53, 61-68) also respects zoom state when fetching blocks, so the zoomed path is consistent end-to-end.

### 2d. Risk of data loss or double-writes? -- MINIMAL (HIGH confidence)

- **Data loss risk**: `flushContentToDatabase()` parses `editorState.content` (the latest editor content) and writes it. Since `content` already reflects the editor state (via push-based messaging + polling), this is a safe idempotent operation. If blocks were already up-to-date, the `replaceBlocks()` call writes the same data -- no loss.
- **Double-write risk**: The function cancels `blockReparseTask` (line 353-354), so the subsequent BlockSyncService poll won't conflict. Even if BlockSyncService polls concurrently after the flush, it would see the image block is already in the DB and skip the insert -- no duplication.
- **Metadata preservation**: The function preserves heading metadata (status, tags, wordGoal) from existing blocks (lines 358-366), so no section metadata is lost during the flush.

---

## 3. Check for Similar Gaps

I examined all locations in the codebase that compute character offsets from blocks (the `blockOffset[block.id] = offset` pattern) and assess whether each one has a stale-block risk.

### 3a. `ContentView+ContentRebuilding.swift` -- `updateSourceContentIfNeeded()` (line 128)

This function computes offsets from blocks without flushing first. However, it is called in response to content rebuilding events (drag-drop, hierarchy enforcement) where the content is being rebuilt FROM the database. In those flows, the database IS the source of truth and `editorState.content` is being SET from blocks, not the other way around. The blocks and content are already in sync by construction.

**Risk**: LOW. Not an issue because content is derived from DB in this path.

### 3b. `ContentView+SectionManagement.swift` -- `finalizeSectionReorder()` (line 238)

This function computes offsets during drag-drop reorder. It sets `contentState = .dragReorder` first (suppressing polling), then reads blocks. This is a DB-first operation where the user is reorganizing sections via the sidebar, not typing in the editor. Content is rebuilt from DB afterward.

**Risk**: LOW. Drag-drop is a DB-first operation; no editor content is being "lost" here.

### 3c. `ContentView+HierarchyEnforcement.swift` -- `rebuildDocumentContentStatic()` (line 121)

This static function reads blocks and rebuilds content. It also computes offsets for source mode. Like 3a, this is a DB-to-editor flow where content is assembled from blocks.

**Risk**: LOW. Same reasoning as 3a.

### 3d. `EditorViewState+Zoom.swift` -- `zoomToSection()` (line 75) and `zoomOut()` (line 237)

Both of these functions DO call `flushContentToDatabase()` before reading blocks:
- `zoomToSection()` calls it at line 85
- `zoomOut()` calls it at line 251

**Risk**: NONE. Already properly handled.

### 3e. Summary of similar gaps

The ONLY location with a genuine stale-block risk is the one identified in the plan: the WYSIWYG-to-source switch in `ViewNotificationModifiers.swift` (lines 43-100). All other offset computation sites either (a) already flush first, or (b) operate in DB-first flows where content is derived from blocks rather than the reverse.

---

## 4. Overall Assessment

### What was done well

- The root cause analysis is precise and well-reasoned. The plan correctly identifies the asymmetry between the two editor switch directions.
- The fix is minimal (one line of code + comment) and follows existing patterns (mirrors line 104, mirrors zoom operations at lines 85 and 251).
- The "Why This Works" section in the plan accurately describes the causal chain.
- The verification steps are appropriate.

### Issues Found

**No critical or important issues.** The proposed fix is correct and safe.

### One minor suggestion (NICE TO HAVE, LOW priority)

The plan says to add the flush "at line 45 (after setting `contentState = .editorTransition`)". The exact placement is correct -- it must be AFTER setting `contentState` (to suppress polling/observation during the flush) and BEFORE the `fetchBlocks` call. I would suggest placing it immediately before the "Compute offsets" comment block (before line 55) rather than immediately after line 45, so it is visually co-located with the code it protects. But this is purely a readability preference; either position is functionally equivalent since the code between lines 45 and 55 does not interact with the database or `content`.

### Verdict

**APPROVE** -- The proposed fix is correct, minimal, safe, and follows established patterns. It addresses the root cause of the regression without introducing new risks. Proceed with implementation.
