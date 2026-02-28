# Review: Revised Bug 1 Fix - Image Insert Destroys Content

## Validation of the proposed fix by tracing actual code paths

---

## 1. BlockSyncService Poll Flow

**Confidence: HIGH**

Traced through `/Users/niyaro/Documents/Code/ff-dev/images/final final/Services/BlockSyncService.swift`.

The poll chain is:

1. `pollBlockChanges()` (line 179) fires every 2s
2. Calls `checkForChanges()` which evaluates `window.FinalFinal.hasBlockChanges()` in JS
3. If true, calls `getBlockChanges()` which evaluates `JSON.stringify(window.FinalFinal.getBlockChanges())`
4. Decodes the JSON into a `BlockChanges` struct (which contains `inserts: [BlockInsert]`)
5. Calls `applyChanges()` (line 207) which delegates to `database.applyBlockChangesFromEditor(changes, for: projectId)` on a detached utility thread
6. After that returns, any `pendingConfirmations` (temp ID -> permanent ID mappings) are sent back to JS via `confirmBlockIds()`

The `applyBlockChangesFromEditor` method in `Database+Blocks.swift` (line 353) processes inserts at line 443-504. For each `BlockInsert`, it:
- Calculates sort order from `afterBlockId`
- Detects heading type from `markdownFragment`
- Creates a permanent UUID
- Creates and inserts a `Block` record
- Returns the temp->permanent ID mapping

**Verdict: The poll flow WILL correctly detect and create the block.** When the JS `insertImage()` creates a figure node, the block-id-plugin assigns it a `temp-*` ID, and the block-sync-plugin detects it as a new insert with `blockType: "image"`, `markdownFragment`, and `textContent`. The DB insert path handles this correctly.

---

## 2. Block Sync JS Side - Insert Detection

**Confidence: HIGH**

Traced through `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/block-sync-plugin.ts`.

When a new figure node appears in the editor:

1. The `block-id-plugin.ts` `assignBlockIds()` (line 156) runs on every doc change. For a new node with no matching existing ID, it assigns a `temp-*` ID (line 229).

2. The `block-sync-plugin.ts` `snapshotBlocks()` (line 221) iterates top-level nodes. For `figure` nodes specifically:
   - `SYNC_BLOCK_TYPES` includes `'figure'` (line 25)
   - The `effectiveType` is mapped: `node.type.name === 'figure' ? 'image'` (line 233) -- this maps the ProseMirror type name to the `BlockType.image` raw value
   - `markdownFragment` is built by `nodeToMarkdownFragment()` which for `figure` returns: `![${node.attrs.alt || ''}](${node.attrs.src || ''})` (line 177)
   - `textContent` is `node.textContent` (the figure node's text content)

3. `detectChanges()` (line 261) compares old vs new snapshot. For the new temp-ID block, line 292 checks `!oldSnapshot.has(id) && id.startsWith('temp-')` -- since the block-id-plugin assigned a `temp-*` ID, this condition is true, and a `pendingInsert` is created.

4. The `BlockInsert` includes: `{ tempId, blockType: "image", textContent, markdownFragment: "![alt](media/file.webp)", headingLevel: undefined, afterBlockId }`.

**Verdict: Detection works correctly.** The JS side will produce a `BlockInsert` with `blockType: "image"` and `markdownFragment` containing the full `![alt](src)` syntax including whatever `src` was set on the figure node.

---

## 3. `insertImage()` JS Function

**Confidence: HIGH**

Read `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/api-content.ts` lines 492-524.

The function:
1. Gets the `figure` node type from the schema (line 504)
2. Creates a figure node with attrs: `{ src: opts.src, alt: opts.alt, caption: opts.caption, width: opts.width, blockId: opts.blockId }` (lines 510-516)
3. Inserts at end of document: `view.state.tr.insert(view.state.doc.content.size, node)` (line 519)

The figure node schema (in `image-plugin.ts` line 61-73) defines `blockId` as an attribute with default `''`. The node IS created with the `blockId` attribute.

**IMPORTANT FINDING about `blockId`**: The `insertImage()` call passes a `blockId` (a real UUID from Swift, not a temp ID). However, the `block-id-plugin` tracks IDs in a separate `Map<number, string>` keyed by document position -- it does NOT read node attributes. When `assignBlockIds()` runs after the document changes, it will NOT find the figure node's position in `currentBlockIds` (it was just inserted), and since `blockIdZoomMode` is false by default, it will generate a NEW `temp-*` ID for that position (line 229).

This means: **The `blockId` passed from Swift via `insertImage()` is effectively ignored by the block sync system.** The block-id-plugin assigns its own temp ID, block sync detects that temp ID as a new insert, and `applyBlockChangesFromEditor` creates a NEW permanent UUID for the block. The Swift-generated `blockId` in the figure node's attrs is cosmetic only (used by the NodeView for `data-block-id` display attribute and for `updateImageMeta` messages from caption/resize).

**This is a problem for the plan's step 4** (auto-populating `imageSrc`/`imageAlt` from `markdownFragment`). The block created by block sync will have a DIFFERENT ID than the one Swift generated. If Swift calls `updateBlockImageMeta(id: blockId, ...)` with the original Swift-generated UUID, it will fail because no block with that ID exists in the DB -- the actual block has a different permanent UUID assigned by `applyBlockChangesFromEditor`.

---

## 4. Race Condition Check

**Confidence: HIGH**

With the DB write removed (only the JS call remains), the race condition from the original bug is eliminated. There is no longer a dual-write scenario.

However, there is a **sequencing concern**: The `insertImage()` JS call dispatches a ProseMirror transaction synchronously. This triggers `assignBlockIds()` and `detectChanges()` (with a 100ms debounce). The block sync poll runs every 2s. The timeline is:

1. T=0: Swift calls `insertImage()` via `evaluateJavaScript`
2. T=0: ProseMirror dispatches transaction, `assignBlockIds()` runs, assigns `temp-*` ID
3. T=100ms: Debounced `detectChanges()` fires, records `pendingInsert`
4. T=next-2s-tick: `pollBlockChanges()` detects `hasBlockChanges() == true`, fetches and applies insert

No race. The JS insertion is synchronous, the block-id assignment is synchronous, the change detection is debounced but resolves well before the next poll. The poll consumes the pending insert atomically.

**Verdict: No race condition with the proposed fix.** The editor-first approach is clean.

---

## 5. `updateBlockImageMeta` and Auto-Populating from `markdownFragment`

**Confidence: HIGH**

Read `/Users/niyaro/Documents/Code/ff-dev/images/final final/Models/Database+Blocks.swift` lines 510-542.

`updateBlockImageMeta()` (line 513) does a `Block.fetchOne(db, key: id)` and then updates individual columns. If the block does not exist, it prints a warning and returns (line 522).

The plan proposes: In `applyBlockChangesFromEditor`, when processing an insert with `blockType == .image`, auto-populate `imageSrc` and `imageAlt` from `markdownFragment`.

Looking at the insert processing (lines 443-504): After creating the `Block`, the code already populates `textContent` and `markdownFragment` from the `BlockInsert`. The `markdownFragment` for an image would be `![alt](media/file.webp)`. The proposal is to parse this and extract `imageSrc` and `imageAlt`.

**This is feasible and straightforward.** The insert path already does regex parsing for headings (lines 470-476). Adding a similar regex for `![alt](src)` is natural:

```swift
// After existing heading detection, add:
if blockType == .image || insert.blockType == "image" {
    // Parse ![alt](src) from markdownFragment
    let imgPattern = #"^!\[([^\]]*)\]\(([^)]+)\)$"#
    if let match = insertTrimmed.range(of: imgPattern, options: .regularExpression) {
        // Extract alt and src
        ...
        block.imageSrc = extractedSrc
        block.imageAlt = extractedAlt
    }
}
```

**However**: As noted in finding 3, the `blockId` from Swift will NOT match the permanent ID assigned by block sync. So calling `updateBlockImageMeta(id: swiftBlockId)` after the JS call would update a non-existent block. The auto-populate approach in `applyBlockChangesFromEditor` is the correct solution because it uses the permanent ID at creation time.

**Verdict: The auto-populate approach is sound and avoids the ID mismatch problem.**

---

## 6. Edge Case: Project Switch Before 2s Poll

**Confidence: HIGH**

Traced through `/Users/niyaro/Documents/Code/ff-dev/images/final final/Views/ContentView+ProjectLifecycle.swift`.

When the user switches projects, `handleProjectOpened()` (line 180) executes:
1. `blockSyncService.stopPolling()` -- stops the 2s timer
2. `await flushAllPendingContent()` -- fetches content from WebView via `getContent()`, then calls `flushContentToDatabase()` which re-parses ALL content via `BlockParser.parse(markdown:)` and calls `db.replaceBlocks(blocks, for: pid)`

The key insight is step 2: `flushContentToDatabase()` does a FULL reparse of the current editor markdown content. If the figure node is in the editor (from the JS `insertImage()` call), then `getContent()` will serialize it as `![alt](media/file.webp)`, and `BlockParser.parse()` will create a proper image block from that markdown.

Similarly, `performProjectClose()` (line 262) calls `editorState.flushContentToDatabase()` which does the same full reparse.

**Verdict: The edge case is handled.** Even if the user switches projects before the 2s poll, the full content flush re-parses the markdown and creates the image block. The only potential issue is whether `BlockParser.parse()` correctly sets `imageSrc`/`imageAlt` from `![alt](src)` syntax.

Let me verify that.

---

## 7. Additional Finding: BlockParser and Image Blocks

To fully validate the edge case, we need to confirm that `BlockParser.parse()` correctly creates image blocks with `imageSrc`/`imageAlt`. If `BlockParser` does NOT set these image metadata columns (because it only sets `markdownFragment` and `textContent`), then both the block sync path AND the flush path would produce image blocks without metadata columns.

This is the same gap the plan identifies. The fix (auto-populate in `applyBlockChangesFromEditor`) only covers the block sync path. The `flushContentToDatabase()` path uses `BlockParser.parse()` + `replaceBlocks()`, which is a separate code path. If `BlockParser.parse()` does not set image columns, the flush path would also lose them.

**Recommendation**: The `markdownFragment` regex parsing for image metadata should be added in BOTH places:
1. `applyBlockChangesFromEditor` insert path (for block sync)
2. `BlockParser.parse()` (for full re-parse/flush)

Or alternatively, add a post-processing step to `Block.init` or `recalculateWordCount()` that auto-populates image columns from `markdownFragment` whenever `blockType == .image`.

---

## Summary of Findings

| Question | Verdict | Confidence |
|----------|---------|------------|
| 1. BlockSyncService poll creates block correctly? | YES | HIGH |
| 2. JS block-sync detects new figure as insert? | YES | HIGH |
| 3. `insertImage()` creates correct figure node? | YES, but `blockId` param is ignored by block-id-plugin | HIGH |
| 4. Race condition eliminated? | YES | HIGH |
| 5. Auto-populate `imageSrc`/`imageAlt` feasible? | YES, and it is the correct approach (avoids ID mismatch) | HIGH |
| 6. Project switch before poll -- data loss? | NO -- `flushContentToDatabase()` re-parses all content | HIGH |

## Issues Identified

### Important (should fix)

**A. The `blockId` passed from Swift to `insertImage()` is not tracked by block-id-plugin.** The block-id-plugin assigns its own `temp-*` ID to the new figure node, so the permanent block ID in the DB will be different from what Swift originally generated. This means:
- The plan's suggested `updateBlockImageMeta(id: blockId)` call (in the simplified `insertImageBlock()`) will fail because no block with that `blockId` exists in DB.
- The figure node's `blockId` attribute (used by NodeView for caption/resize `updateImageMeta` messages) will also be wrong -- it will hold the Swift UUID, but the DB block has a different ID.

**Fix**: Either (a) after block sync confirms the temp ID, update the figure node's `blockId` attribute to the permanent ID; or (b) don't pass `blockId` from Swift at all -- let the temp ID flow through naturally, and after block sync confirms, the confirmed permanent ID will be available. The `updateImageMeta` messages from the NodeView use `this.node.attrs.blockId`, so the figure node needs the correct (permanent) DB ID eventually.

Currently, the `confirmBlockIdsApi()` function (api-content.ts line 472) calls `confirmBlockIdsPlugin(mapping)` and `applyPendingConfirmations()` and `updateSnapshotIds()`, but it does NOT update figure node attributes. The confirmed IDs live only in the block-id-plugin's position map and decorations (`data-block-id` attribute on the DOM). The figure node's `attrs.blockId` remains whatever was set at creation time.

**B. Image metadata columns must be populated in BOTH code paths**: `applyBlockChangesFromEditor` (block sync) AND `BlockParser.parse()` (full reparse/flush). The plan only mentions the first.

### Suggestions (nice to have)

**C. Consider removing the `blockId` parameter from the `insertImage()` JS call entirely.** Since the block-id-plugin assigns its own temp ID anyway, passing a Swift UUID is misleading and creates the ID mismatch described in Issue A. Instead, let the figure node get a temp ID naturally, and after block sync confirms it, the confirmed permanent ID should be set as the figure's `blockId` attribute.
