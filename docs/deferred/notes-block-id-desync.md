# Notes Block ID Desync

**Date**: 2026-02-22
**Status**: Deferred (interim fix in place)
**Affects**: Footnote definition text persistence in Notes section

## Summary

When footnotes are inserted via the immediate insertion path, Notes blocks are created in the GRDB database with real UUIDs but pushed to the JS editor via `setContent()` instead of `setContentWithBlockIds()`. The JS editor never learns the real UUIDs, assigns temporary IDs to the Notes blocks, and subsequent polling cannot match editor changes back to the correct DB blocks. This causes user-typed definition text to exist only in the editor and never reach the database — violating the app's "database is single source of truth" principle.

## Architecture Context

The app's block sync system works as follows:

1. Content is divided into blocks (paragraphs, headings) stored in GRDB, each with a UUID.
2. The JS editor has a block ID plugin that tracks which DOM node corresponds to which DB block.
3. `setContentWithBlockIds(markdown, blockIds)` pushes content and IDs atomically — JS knows the mapping.
4. `setContent(markdown)` pushes content only — JS generates temporary IDs (e.g., `temp-abc123`).
5. `BlockSyncService` polls the JS editor every ~300ms, gets block changes with IDs, and syncs back to DB.
6. Without real block IDs, the poll cannot match changes to the right DB blocks.

The bibliography section does NOT have this problem because `.bibliographySectionChanged` uses the correct atomic path: `fetchBlocksWithIds()` → `setContentWithBlockIds()`.

## The Desync Mechanism

Step-by-step sequence when a user inserts a footnote via slash command:

1. **User types `/footnote`** in the editor. The slash command handler posts `.footnoteInsertedImmediate` with the footnote label.

2. **ContentView receives the notification** (ContentView.swift, line 221). It sets `contentState = .bibliographyUpdate` and `isSyncSuppressed = true` to prevent poll interference.

3. **`handleImmediateInsertion()` runs** (FootnoteSyncService.swift). It:
   - Reads existing footnote definition blocks from DB
   - Deletes ALL notes blocks (`Block.filter(...isNotes == true).deleteAll(db)`)
   - Creates new notes blocks with fresh UUIDs, including a definition for the new footnote
   - Re-sorts all blocks (body → notes → bibliography)

4. **ContentView builds combined markdown** from the stripped editor content + newly generated Notes section markdown + bibliography. It sets `editorState.content = combined`.

5. **Content is pushed via `setContent()`** — specifically, `editorState.isResettingContent` is set to `false` and `contentState` to `.idle`, which allows `updateNSView` to detect the content change and call `setContent(combined)` on the WebView. This is NOT the atomic `setContentWithBlockIds()` path.

6. **JS editor receives content, assigns temp IDs** to all blocks (including the Notes blocks that have real UUIDs in DB).

7. **Sync suppression is released** (`blockSyncService.isSyncSuppressed = false`). Polling resumes.

8. **User types into a definition line.** The next poll picks up the change.

9. **`BlockSyncService` tries to match the temp ID to a DB block — fails.** The temp ID (e.g., `temp-abc123`) does not exist in the database.

10. **The temp block gets "promoted" to a new DB block** via `Database+Blocks.swift` (`update.id.hasPrefix("temp-")`). A brand-new block with a new UUID is created.

11. **The original Notes blocks** (created by `handleImmediateInsertion` in step 3) retain their empty definition text because no poll ever matched them.

12. **When the user inserts the next footnote**, `handleImmediateInsertion` reads the original (empty) blocks from DB, deletes all notes blocks, and recreates them — losing the user's typed text.

## Log Evidence

After user typed text into footnote 1's definition, then inserted footnote 2:

```
[DIAG-FN] existing dbDefs: ["1": ""]   # Should have user's text, but it's empty
```

After user typed text into footnotes 1 and 2, then inserted footnote 3:

```
[DIAG-FN] existing dbDefs: ["1": "", "2": ""]   # Both empty
```

The definitions are empty because `handleImmediateInsertion` reads from DB blocks that were never updated (the editor's changes went to duplicate temp-promoted blocks instead).

## Root Cause

The v3 fix for a stale content push bug intentionally switched the immediate insertion path from `setContentWithBlockIds()` to `setContent()`. The reason: `fetchBlocksWithIds()` reads ALL blocks from DB — including stale body blocks that still contained old slash command text (e.g., `/foo` instead of `[^1]`). The stale body blocks would overwrite the editor's correct ProseMirror state.

The v3 plan noted this as a "known limitation" expecting the poll to self-heal, but the block ID desync prevents self-healing because the poll cannot match temp IDs to the right DB blocks.

### Why fetchBlocksWithIds() is unsafe here

`fetchBlocksWithIds()` (in `ContentView+ContentRebuilding.swift`) calls `db.fetchBlocks(projectId:)`, reassembles markdown from each block's `markdownFragment` field, and returns block IDs in sort order. The body blocks' `markdownFragment` values reflect the last time the poll synced them to DB — which may lag behind the editor by up to 300ms or more. If the user added or removed paragraphs since the last sync, the block count and content in DB will not match the editor.

## Impact

This desync violates the app's core architecture principle:

- **Data loss on insertion**: User-typed definition text lives only in the editor, not in DB. Each new footnote insertion wipes it.
- **Data loss on crash**: If the app crashes before the definitions are synced by another path, text is lost.
- **Data loss on editor switch**: Switching between Milkdown and CodeMirror rebuilds content from DB, losing unsynced definition text.
- **Data loss on zoom out**: Zooming out of a section rebuilds from DB.
- **Debounce path conflict**: The 3-second debounced `checkAndUpdateFootnotes` also reads from DB, potentially overwriting good content with empty definitions.

## Scope

**Affected**:
- Notes section blocks created by the immediate insertion path
- Any user edits to those blocks until a full content rebuild reconciles them
- Potentially other paths that use `setContent()` without `setContentWithBlockIds()` (audit needed)

**Not affected**:
- Bibliography section (uses `fetchBlocksWithIds()` → `setContentWithBlockIds()`)
- Regular body text blocks (poll matches them by existing IDs)
- The `.notesSectionChanged` notification handler (also uses the correct atomic path)

## Approaches to Fix

### Approach 1: Build block ID list manually after immediate insertion

After `handleImmediateInsertion` creates Notes blocks and the combined content is assembled, manually construct a block ID list:

1. Get body block IDs from DB (in sort order)
2. Get Notes block IDs (just created by `handleImmediateInsertion`)
3. Get bibliography block IDs from DB (in sort order)
4. Concatenate: body IDs + Notes IDs + bibliography IDs
5. Call `setContentWithBlockIds(combined, manualIds)` instead of `setContent(combined)`

**Risk**: The body blocks in DB are stale — their count/content may not match the editor's body content. If the user added/removed paragraphs since the last sync, the ID count will not match and IDs get assigned to wrong blocks.

**Mitigation**: Count body paragraphs in the stripped editor content and compare to body block count in DB. If they differ, fall back to `setContent()` without IDs (accepting the desync for that insertion).

### Approach 2: Two-phase push — content first, then IDs

1. Push content via `setContent(combined)` (current approach)
2. Wait for the next poll cycle (~500ms) to process the content
3. Then call `pushBlockIds()` which re-reads blocks from DB (now including newly created Notes blocks)

**Risk**: Between steps 1 and 3, there is a window where edits could be lost. Also, `pushBlockIds` uses `fetchBlocksWithIds()` which still has the stale body block problem — the ID count from DB may not match the paragraph count in the editor.

### Approach 3: Sync body blocks to DB before creating Notes blocks

Before calling `handleImmediateInsertion`, force-sync the fresh editor content to DB body blocks:

1. Parse the fresh `editorState.content` into blocks
2. Match to existing DB blocks by position
3. Update DB blocks with fresh content
4. Then call `handleImmediateInsertion` which reads from (now-fresh) DB
5. Then call `setContentWithBlockIds()` (now safe because DB is fresh)

**Risk**: Force-syncing body blocks outside the normal polling cycle could conflict with in-flight poll updates. Would need careful sync suppression. This is also the most complex approach.

### Approach 4: Have handleImmediateInsertion return block IDs

Modify `handleImmediateInsertion` to return the list of all block IDs (body + notes + bibliography) in sort order. The body block IDs come from DB (unchanged), notes block IDs are the newly created ones, bibliography block IDs come from DB.

Then in ContentView, use `setContentWithBlockIds(combined, returnedIds)`.

**Same risk as Approach 1**: body block count mismatch if user added/removed paragraphs since last sync.

### Recommended Approach

**Approach 1 with count validation** is likely the safest incremental fix:

- Build the ID list manually in ContentView after `handleImmediateInsertion` returns
- Validate that body block count in DB matches the paragraph count in the stripped editor content
- If counts match, use `setContentWithBlockIds(combined, manualIds)` for full sync
- If counts do not match, fall back to `setContent(combined)` and accept the desync for that insertion
- This preserves the DB-as-truth principle for Notes blocks in the common case while handling the body block staleness edge case gracefully

## Interim Fix (v4)

While this architectural issue is being resolved, the immediate text loss bug is fixed by reading existing definitions from the fresh editor content (not from DB blocks) when inserting a new footnote. This is a symptom-level fix — it prevents text loss during the insertion flow but does not fix the underlying block ID desync. The Notes blocks in DB still have empty text until another sync path reconciles them.

## Files Involved

| File | Role in this bug |
|------|-----------------|
| `FootnoteSyncService.swift` | `handleImmediateInsertion()` creates Notes blocks in DB with real UUIDs |
| `ContentView.swift` | `.footnoteInsertedImmediate` handler pushes content via `setContent()` (not atomic) |
| `ContentView+ContentRebuilding.swift` | `fetchBlocksWithIds()` — reads all blocks from DB (stale body block problem) |
| `BlockSyncService.swift` | `pushBlockIds()`, `setContentWithBlockIds()`, polling loop |
| `Database+Blocks.swift` | `applyBlockChangesFromEditor()` — promotes unmatched temp IDs to new blocks |
| `MilkdownCoordinator+Content.swift` | `setContent()` vs `setContentWithBlockIds()` — the two push paths |

## Comparison: Bibliography vs Notes Insertion

| Aspect | Bibliography (works) | Notes immediate insertion (broken) |
|--------|--------------------|------------------------------------|
| DB write | Creates/updates bib blocks | Creates notes blocks with real UUIDs |
| Content push | `fetchBlocksWithIds()` → `setContentWithBlockIds()` | `setContent()` via `updateNSView` |
| JS block IDs | Real UUIDs from DB | Temp IDs assigned by JS |
| Poll matching | IDs match → updates correct blocks | IDs don't match → promotes to duplicates |
| User edits persist | Yes, in correct DB blocks | No, stuck in temp-promoted duplicates |

The fix should bring the Notes immediate insertion path in line with the bibliography path's atomic content+ID push pattern.
