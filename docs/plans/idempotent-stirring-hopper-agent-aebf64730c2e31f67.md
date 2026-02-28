# Code Review: Bug Fix Plan for Image Feature

## Review of `/Users/niyaro/Documents/Code/ff-dev/images/docs/plans/idempotent-stirring-hopper.md`

Reviewer focused on Bug 1 (image insert destroys content) and Bug 2 (version restore destroys data).

---

## Bug 1: Image Insert Destroys Content

### Diagnosis Validation

**The dual-modification diagnosis is correct.** Tracing through the code confirms two conflicting writes:

1. **DB write** at line 844 of `MilkdownCoordinator+MessageHandlers.swift`:
   ```swift
   try db.applyBlockChanges([.insert(block)], for: projectId)
   ```
   This writes the new image block to the database.

2. **JS write** at lines 851-858:
   ```swift
   let srcForDisplay = src.replacingOccurrences(of: "media/", with: "")
   webView?.evaluateJavaScript(
       "window.FinalFinal.insertImage && window.FinalFinal.insertImage({src: `\(srcForDisplay)`, ...})"
   )
   ```
   This directly inserts a figure node into the ProseMirror document.

**The src path stripping is also correctly identified.** Line 851 strips `media/` from the src, but the JS `insertImage` function at `web/milkdown/src/api-content.ts:492-524` creates a figure node with `src: opts.src`. The figure NodeView's `rewriteUrl()` expects the `media/` prefix to convert it to `projectmedia://`. Without the prefix, the image URL would resolve incorrectly.

**Race condition confirmed:** The DB write at line 844 does NOT trigger any automatic push to the editor. BlockSyncService's polling (2-second interval) goes editor-to-DB only -- it calls `getBlockChanges()` from JS and writes to the DB. There is no DB-to-editor polling path. So the two writes are not technically "racing" in the traditional sense; rather, both happen, and the next poll cycle picks up the JS-inserted node as a "new" block (with a temp ID), causing a duplicate insert or content corruption when the block sync tries to reconcile.

### Proposed Fix Validation: CRITICAL PROBLEM

**The proposed fix (remove lines 850-858) will NOT work as described in the plan.**

The plan states:
> "The DB insert at line 844 will trigger BlockSyncService, which will detect the new image block and push it to the editor through `applyBlocks()` -- the same mechanism that handles all other block types."

**This is incorrect.** After thorough code review:

1. **BlockSyncService polls one direction only: editor -> DB.** Its `pollBlockChanges()` method (lines 178-219 of `BlockSyncService.swift`) calls `getBlockChanges()` from the JS editor, then writes those changes to the database. It never reads from the DB and pushes to the editor on its own.

2. **`applyBlocks()` is a JS function** exposed on `window.FinalFinal` (line 333 of `main.ts`), but it is **never called from Swift**. A grep for `applyBlocks` in all `.swift` files returned zero results.

3. **The DB ValueObservation** (`Database+BlocksObservation.swift`) only observes outline blocks (headings + pseudo-sections) for sidebar display. It does NOT trigger content pushes to the editor.

4. **`setContentWithBlockIds()`** is the mechanism that pushes blocks to the editor, but it is only called during project open, project switch, bibliography updates, footnote updates, and zoom transitions -- NOT in response to individual block insertions.

**If you remove the JS `insertImage` call and only do the DB write, the image will be saved in the database but will NOT appear in the editor until the user switches projects or performs some other operation that triggers a full content reload.**

### Recommended Fix for Bug 1

The fix needs to take one of two approaches:

**Option A (Simpler -- fix the JS call, remove the DB call):** Keep the `insertImage` JS call (lines 852-858) but fix the src path (don't strip `media/`). Remove the separate `applyBlockChanges` DB call at line 844. Let the BlockSyncService polling (2s interval) pick up the new figure node from the editor and create the DB block through the normal editor -> DB sync path.

Pros: Follows the same flow as user typing (editor first, DB sync follows).
Cons: Block won't be in DB immediately; up to 2 seconds delay. If the app crashes in that window, the image is lost from the DB (but visible in editor).

**Option B (More robust -- DB write then full content push):** Keep the DB write at line 844, remove the JS `insertImage` call, AND add an explicit content push after the DB write. After inserting the block, call `blockSyncService.setContentWithBlockIds()` to push the updated block list (including the new image) to the editor. This is the same pattern used by bibliography and footnote updates.

Pros: DB is source of truth immediately; editor reflects the DB state.
Cons: Replaces entire document content (cursor position may jump); requires access to `blockSyncService` from `MilkdownCoordinator+MessageHandlers`, which currently does not have a reference to it.

**Option C (Simplest -- fix the JS call only):** Keep both the DB write AND the JS call, but fix the src path issue (don't strip `media/`). Then handle the fact that the next poll will see the block in both the editor (from JS insert) and the DB (from Swift insert). The block ID is the same in both (`blockId`), so the poll should recognize them as the same block.

Pros: Minimal change. Cons: Need to verify that the block sync reconciliation handles this case correctly (block exists in both DB and editor with same ID).

**I recommend Option A or Option C.** The plan's proposed fix (Option B without the push step) will silently break image insertion.

---

## Bug 2: Version Restore Destroys Data

### Diagnosis Validation

**The diagnosis is correct.** Tracing the actual code paths:

1. `performFullRestore()` in `VersionHistoryWindow+Restore.swift:185-207` calls:
   ```swift
   try service.restoreEntireProject(from: snapshotId, createSafetyBackup: createSafetyBackup)
   NotificationCenter.default.post(name: .projectDidOpen, object: nil)
   ```

2. `restoreEntireProject()` in `SnapshotService.swift:89-122` restores `content.markdown` and sections but does NOT touch the blocks table.

3. The `.projectDidOpen` notification is received in `ViewNotificationModifiers.swift:207`:
   ```swift
   .onReceive(NotificationCenter.default.publisher(for: .projectDidOpen)) { _ in
       Task { await onOpened() }
   }
   ```
   Which calls `ContentView.handleProjectOpened()`.

4. `handleProjectOpened()` in `ContentView+ProjectLifecycle.swift:180-248`:
   - Line 187: Calls `await flushAllPendingContent()` -- this fetches pre-restore content from the WebView and writes it to the DB (blocks), overwriting any restored content.
   - Line 212: Calls `await configureForCurrentProject()` which loads from blocks -- now containing stale pre-restore data.

**The plan's note that this is a pre-existing bug is also correct.** The restore flow uses `.projectDidOpen` which was designed for switching between different projects, not for same-project restores.

### Proposed Fix Validation

**The flag approach will work, but has issues worth addressing.**

The proposed fix:
```swift
if SnapshotService.didJustRestore {
    SnapshotService.didJustRestore = false
    // Skip flush
} else {
    await flushAllPendingContent()
}
```

**Issue 1: Static mutable state on a @MainActor class.**
`SnapshotService` is `@MainActor final class` with an instance-based design (initialized with a specific database and projectId). Adding `static var didJustRestore` introduces global mutable state that crosses instance boundaries. This works but is architecturally awkward.

**Issue 2: The flag must also skip the content push in `handleProjectOpened`.**
Looking at lines 217-247, after `flushAllPendingContent()`, the method calls `configureForCurrentProject()` (line 212) which loads content from blocks. But the blocks table is stale (not restored). The flag must ALSO trigger block re-parsing from the restored content. Currently `configureForCurrentProject()` at lines 110-114 checks if blocks exist:
```swift
if !existingBlocks.isEmpty {
    editorState.content = BlockParser.assembleMarkdown(from: existingBlocks)
```
Since old blocks exist, it will assemble from stale blocks, NOT from the restored `content.markdown`.

**This means the flag approach alone is insufficient.** Even if you skip the flush, the blocks table still contains pre-restore data, and `configureForCurrentProject` will load from those stale blocks.

**Issue 3: Other `.projectDidOpen` callers.**
The notification is posted from four locations:
1. `FileCommands.swift:136` -- opening a recent project (flush SHOULD happen)
2. `FileCommands.swift:229` -- opening a project via Open dialog (flush SHOULD happen)
3. `VersionHistoryWindow+Restore.swift:172` -- section restore (flush should be skipped)
4. `VersionHistoryWindow+Restore.swift:200` -- full project restore (flush should be skipped)

The flag correctly differentiates these cases since only the restore paths set it.

**Issue 4: Section-level restore (`performSectionRestore`) also posts `.projectDidOpen`.**
At `VersionHistoryWindow+Restore.swift:172`, `performSectionRestore` calls `restoreSectionReplace` or `restoreSectionAsDuplicate`, neither of which sets the `didJustRestore` flag. The plan only mentions setting it in `restoreEntireProject`. Section-level restores might have the same flush problem, though the impact may be smaller since they modify sections, not blocks.

### Recommended Fix for Bug 2

The plan's "cleaner fix" alternative (mentioned but not recommended) is actually the better approach:

**Have `restoreEntireProject()` also rebuild blocks from the restored content.** After restoring sections and `content.markdown`, call `BlockParser.parse()` on the restored markdown and `db.replaceBlocks()`. This makes the blocks table consistent with the restored content.

With this approach:
- Even if `flushAllPendingContent()` runs and writes stale editor content to blocks, `configureForCurrentProject()` will reload from blocks -- but by that point, the full project reload will have already set fresh content from the DB.
- Actually, the flush still writes stale data to blocks, which then gets loaded. So you still need the flag OR you need to ensure the restored blocks survive the flush.

**The most robust approach combines both:**
1. Add `static var didJustRestore = false` flag (as proposed)
2. In `restoreEntireProject()`, also rebuild blocks from restored content:
   ```swift
   let blocks = BlockParser.parse(markdown: snapshot.previewMarkdown, projectId: projectId)
   try database.replaceBlocks(blocks, for: projectId)
   ```
3. In `handleProjectOpened()`, skip `flushAllPendingContent()` when flag is true
4. Set the flag in both `restoreEntireProject` AND in the section restore methods

This way, even if the flag is somehow missed, the blocks table is at least consistent with the restored content.

---

## Summary of Findings

| Item | Diagnosis Correct? | Proposed Fix Correct? | Risk |
|------|--------------------|-----------------------|------|
| Bug 1: Dual modification | Yes | **No -- fix will silently break image insertion** | Critical |
| Bug 1: src path stripping | Yes | Yes (but moot if JS call is removed) | -- |
| Bug 2: Flush overwrites restore | Yes | Partially -- blocks also need rebuilding | Important |
| Bug 2: Flag approach | N/A | Works for flush skip, but blocks table still stale | Important |

### Critical Action Items

1. **Bug 1**: The plan must be revised. Removing the JS call without adding an explicit DB-to-editor push will cause images to be saved in the DB but never appear in the editor. Either fix the JS call (Option A/C above), or add a `setContentWithBlockIds` call after the DB write (Option B).

2. **Bug 2**: The plan should add block rebuilding in `restoreEntireProject()` in addition to the flag approach. Without rebuilding blocks, `configureForCurrentProject()` will load stale block data even if the flush is skipped.

3. **Bug 2**: Consider whether section-level restores (`restoreSectionReplace`, `restoreSectionAsDuplicate`) need the same flag treatment.
