# Review Round 4: Image Insertion Feature Plan

## Summary

Reviewed the 6 NEW fixes in the plan against the actual codebase. Found 2 HIGH-confidence issues and confirmed the remaining 4 fixes are correct.

---

## Fix 1: Export path — ISSUE FOUND (Important)

**Plan says:** Add `BlockParser.assembleMarkdownForExport(from:)` and update `DocumentManager.loadContentForExport()` (line 300).

**Verified:** `DocumentManager.loadContentForExport()` at line 300 is the only call site for export that goes through Pandoc. The flow is:
- `ExportCommands.swift:32` calls `DocumentManager.shared.loadContentForExport()`
- This calls `BlockParser.assembleMarkdown(from: exportBlocks)` on line 300
- The result is passed to `ExportService.export(content:to:format:settings:)`

**Question asked:** Does `BlockSyncService.assembleMarkdown()` (line 311) also need an export variant?

**Answer: No.** `BlockSyncService.assembleMarkdown()` is used exclusively for internal editor content assembly (pushing content to WKWebView). It is called from `ContentView+ContentRebuilding.swift`, `ContentView+ProjectLifecycle.swift`, `EditorViewState+Zoom.swift`, `SectionSyncService.swift`, and `FootnoteSyncService.swift`. All of these feed content into the editor, where `markdownFragment` (the simple `![alt](src)` form) is what the editor needs. The export-specific format (caption comments + width attributes) would be wrong for the editor.

**Question asked:** Are there any OTHER places that assemble markdown for external consumption?

**ISSUE: Yes -- the QuickLook extension.** The QuickLook extension at `/Users/niyaro/Documents/Code/ff-dev/images/QuickLook Extension/` reads directly from SQLite and renders markdown. However, it reads `content.markdown` from the database (via `SQLiteReader.swift`), not the blocks table. The `content.markdown` field uses `markdownFragment` values (simple form), so QuickLook will show `![alt](media/file.png)` without caption/width. This is probably acceptable for a preview, but worth noting as a known limitation. Not a bug per se, since QuickLook is a preview and the simple markdown is still valid.

**Verdict: Fix 1 is correct.** The export path change is properly scoped. `BlockSyncService.assembleMarkdown()` does NOT need an export variant.

---

## Fix 2: Initial load metadata injection — ISSUE FOUND (Important)

**Plan says:** After the parser creates the doc at line 267 of `api-content.ts`, add a second pass that walks figure nodes and injects `caption`/`width` via `setNodeMarkup()`.

### Sub-question 2a: Are figure nodes present after parsing?

The remark plugin parses `![alt](media/file.png)` into figure nodes. Looking at the `section-break-plugin.ts` pattern (lines 13-21), remark plugins transform mdast nodes in-place before the ProseMirror parser runs. The remark plugin for images would transform `image` mdast nodes into `figure` mdast nodes (similar to how `section-break-plugin.ts` transforms `html` nodes into `sectionBreak` nodes). The ProseMirror `parseMarkdown` handler then matches these custom mdast types and creates `figure` ProseMirror nodes. So yes, figure nodes would be present after `parser(markdown)` at line 267.

### Sub-question 2b: Are figure nodes top-level?

In standard markdown, `![alt](src)` creates an image node that is inline (inside a paragraph). However, the remark plugin in the plan converts these to a custom `figure` mdast node type. The ProseMirror node definition has `group: 'block'`, meaning it is a top-level block node. The `parseMarkdown.runner` would call `state.addNode(type)` (like `section-break-plugin.ts:44-46`), which creates a top-level node.

**ISSUE:** There is a subtle concern here. In standard commonmark mdast, `![alt](src)` produces an `image` node that is a *child of a paragraph*. The remark plugin needs to handle this correctly. Looking at the plan's section 6c: "Must be registered before `commonmark` in `main.ts`". But looking at `main.ts` line 155, `commonmark` is `.use(commonmark)`. The custom plugins that intercept mdast nodes (like `sectionBreakPlugin` at line 149) are registered before `commonmark`.

The critical question is: when the remark plugin runs before commonmark, does it see raw mdast where `![alt](media/file.png)` is still a standalone `image` node, or is it already wrapped in a `paragraph` node? In mdast, a standalone image line `![alt](src)` produces:

```
root
  paragraph
    image
```

So the remark plugin must unwrap the image from its parent paragraph. The `section-break-plugin.ts` doesn't have this problem because `html` nodes in mdast are already top-level. But `image` nodes are inline children of `paragraph`. The remark plugin would need to:
1. Visit `paragraph` nodes
2. Check if they contain only a single `image` child with `src` starting with `media/`
3. Replace the entire paragraph with a `figure` mdast node

This is more complex than what `section-break-plugin.ts` does. The plan's section 6c says the remark plugin "Parses `![alt](media/file.png)` into figure node" but doesn't describe this paragraph-unwrapping logic. This is not necessarily a bug in the plan -- it just means the implementation needs to handle this mdast structure. The plan should explicitly mention that the remark plugin needs to unwrap images from their parent paragraphs.

**Confidence: MEDIUM.** The plan omits the paragraph-unwrapping detail, but a competent implementer would figure this out. Flagging as a documentation gap rather than a correctness issue.

### Sub-question 2c: Is the second transaction within `setSyncPaused(true)`?

Looking at `api-content.ts` lines 264-293, the `applyBlocks()` function:
- Line 264: `setSyncPaused(true)`
- Line 265: `setIsSettingContent(true)`
- Line 267-282: Parse and dispatch first transaction
- Line 286-289: `clearBlockIds()`, `setBlockIdsForTopLevel()`, `resetAndSnapshot()`
- Line 290-292: `finally { setIsSettingContent(false); setSyncPaused(false); }`

The plan says to add the metadata injection after line 288 (`setBlockIdsForTopLevel`) but before the `finally` block. This IS within the `setSyncPaused(true)` block. The plan also explicitly states: "This runs inside the `setSyncPaused(true)` block, so it won't trigger false change detection."

However, `resetAndSnapshot()` at line 289 captures the document as the new baseline. If the metadata injection transaction runs AFTER `resetAndSnapshot()`, the snapshot won't include the new attributes, and the next detectChanges() call would see the figure nodes as "changed" (attribute mismatch). The plan should insert the metadata injection BEFORE `resetAndSnapshot()`:

```
setBlockIdsForTopLevel(blockIds, view.state.doc);  // line 288
// <-- metadata injection here
resetAndSnapshot(view.state.doc);                   // line 289
```

Looking at the plan code more carefully (line 268-286 of the plan), it says "After line 288: setBlockIdsForTopLevel". The `resetAndSnapshot` is at line 289. So the injection goes between lines 288 and 289, which is correct in terms of ordering. But there is an issue: `resetAndSnapshot(view.state.doc)` at line 289 would capture the state BEFORE the metadata dispatch, because `view.dispatch(metaTr)` updates `view.state` but `resetAndSnapshot` is called with the pre-dispatch `view.state.doc`. Wait -- actually, `view.dispatch()` synchronously updates `view.state`, so after the dispatch, `view.state.doc` reflects the new attributes. And `resetAndSnapshot(view.state.doc)` at line 289 would pick up the post-dispatch doc.

**Actually, there IS a problem.** The plan dispatches `metaTr` at line 285: `if (metaTr.steps.length > 0) view.dispatch(metaTr);`. Then line 289 calls `resetAndSnapshot(view.state.doc)`. But `view.state.doc` after the dispatch is the NEW doc (with metadata). However, the block sync plugin's `apply()` method would also fire on this dispatch. Since `syncPaused` is true, the `apply()` returns early (line 336-338 of `block-sync-plugin.ts`), so no change detection occurs. But it also means `lastSnapshot` is NOT updated by the plugin. Then `resetAndSnapshot()` explicitly rebuilds the snapshot from the current doc.

**Verdict: Fix 2 is MOSTLY correct.** The ordering is sound. The metadata injection happens within `setSyncPaused(true)`, and `resetAndSnapshot()` runs after the dispatch so it captures the final state. One documentation gap: the plan should mention that the remark plugin needs to unwrap images from their parent paragraph mdast nodes.

---

## Fix 3: BlockType mapping in snapshotBlocks() — CORRECT

**Plan says:** Add `'figure'` -> `'image'` mapping at line 240 of `block-sync-plugin.ts`.

**Verified the `BlockUpdate` interface (line 29-34):**
```typescript
export interface BlockUpdate {
  id: string;
  textContent?: string;
  markdownFragment?: string;
  headingLevel?: number;
}
```

`BlockUpdate` does NOT include `blockType`. This is correct because updates track content changes to existing blocks -- the block type was already established at insert time. Looking at `detectChanges()` lines 270-283, updates only send `id`, `textContent`, `markdownFragment`, and `headingLevel`. No `blockType` is sent for updates.

**Verified the `BlockInsert` interface (line 36-43):**
```typescript
export interface BlockInsert {
  tempId: string;
  blockType: string;
  textContent: string;
  markdownFragment: string;
  headingLevel?: number;
  afterBlockId?: string;
}
```

`BlockInsert` DOES include `blockType`. Looking at `detectChanges()` lines 287-310, inserts are created with `blockType: newBlock.blockType`. Since `newBlock` comes from the snapshot, and the snapshot uses `effectiveType` (which maps `'figure'` to `'image'`), the insert will correctly send `blockType: 'image'` to Swift. This matches Swift's `BlockType.image` raw value.

**Verified the flow in `detectChanges()`:**
- Updates (line 277): `{ id, textContent: newBlock.textContent, markdownFragment: newBlock.markdownFragment, headingLevel: newBlock.headingLevel }` -- no blockType, correct.
- Inserts (line 301-308): `{ tempId: id, blockType: newBlock.blockType, ... }` -- uses snapshot's `effectiveType`, which includes the `'figure'` -> `'image'` mapping. Correct.

**Verdict: Fix 3 is correct.** The mapping at the snapshot level propagates correctly to both update and insert paths.

---

## Fix 4: Post-parse figure matching — CORRECT

**Plan says:** Match figure nodes to blocks by position order: `figureBlocks = sortedBlocks.filter(b => b.blockType === 'image')`.

**Question:** Is position order guaranteed to match?

`sortedBlocks` is sorted by `sortOrder` (line 258 of `api-content.ts`). The blocks are assembled into markdown by joining `markdownFragment` values in `sortOrder` order (line 261). The parser produces nodes in document order. `doc.forEach()` traverses top-level nodes in document order. Since the markdown is assembled in sortOrder, and figure nodes appear in the document in the same order as their source blocks, the position order matches.

**Question:** What happens with 0 image blocks?

`figureBlocks` would be an empty array. `figureIdx` starts at 0. The `doc.forEach` would never enter the `if (node.type.name === 'figure' && figureIdx < figureBlocks.length)` branch because `figureBlocks.length === 0`. `metaTr.steps.length` would be 0, so the dispatch is skipped. This is handled correctly.

**Question:** What about mixed content?

If blocks are [text, image, text, image], the markdown assembles as: `text\n\n![alt](src)\n\ntext\n\n![alt](src)`. The parser produces: [paragraph, figure, paragraph, figure]. `figureBlocks` contains the 2 image blocks in order. `doc.forEach` iterates all 4 nodes, but only increments `figureIdx` for figure nodes, matching them 1:1 with `figureBlocks`. Correct.

**Verdict: Fix 4 is correct.**

---

## Fix 5: Remark plugin + figure node — ISSUE (Documentation gap)

**Plan says:** The remark plugin registered before commonmark will parse `![alt](media/file.png)` into figure nodes.

**How does `section-break-plugin.ts` register its remark plugin?**

It uses `$remark('section-break', () => ...)` from `@milkdown/kit/utils` (line 6, 13). The plugin is exported as part of `sectionBreakPlugin: MilkdownPlugin[]` (line 59). This is the standard Milkdown way.

**How does the remark plugin distinguish local images from remote images?**

The plan says (section 6c): "Parses `![alt](media/file.png)` into figure node". This implies the remark plugin should only match images whose `src` starts with `media/`. Remote images like `![alt](https://example.com/img.png)` would remain as standard inline images.

**If ALL images become figure nodes, would that break inline images?**

Yes, it would. But the plan's intent is to only convert `media/`-prefixed images. The remark plugin should check `node.url.startsWith('media/')` before converting. The plan mentions this distinction but doesn't spell out the URL check in the remark plugin code.

**As noted in Fix 2 review:** The remark plugin also needs to handle the mdast structure where images are children of paragraphs, not top-level nodes. This is a documentation gap in the plan.

**Verdict: Fix 5 is correct in intent.** The remark plugin should only convert `media/`-prefixed images, preserving inline images. Implementation needs two things the plan doesn't explicitly spell out: (1) URL prefix check, (2) paragraph unwrapping.

---

## Fix 6: spellcheck-plugin.ts SKIP_NODE_TYPES — CORRECT

**Plan says:** Add `'figure'` to `SKIP_NODE_TYPES` in `spellcheck-plugin.ts:116`.

**Current `SKIP_NODE_TYPES` (lines 113-120):**
```typescript
const SKIP_NODE_TYPES = new Set([
  'code_block',
  'fence',
  'image',
  'html_block',
  'auto_bibliography_start',
  'auto_bibliography_end',
]);
```

Adding `'figure'` here is correct -- figure nodes are atom nodes with no inline text content to spellcheck.

**Are there other plugins with node type lists that should include `'figure'`?**

Searched all `node.type.name` comparisons across TypeScript files. Key findings:

1. **`block-sync-plugin.ts` SYNC_BLOCK_TYPES (line 15-26):** Plan says replace `'image'` with `'figure'`. Correct.

2. **`block-id-plugin.ts` BLOCK_TYPES (line 13-24):** Plan says replace `'image'` with `'figure'`. Correct.

3. **`source-mode-plugin.ts`:** This plugin adds markdown syntax decorations. It handles `blockquote`, `bullet_list`, `ordered_list`, `code_block`, `horizontal_rule`. It does NOT have a node type list -- it uses individual `if (node.type.name === ...)` checks. For `figure` nodes, the plan says the NodeView handles source mode rendering (section 6b: "Check `isSourceModeEnabled()` and render raw markdown text"). Since the NodeView manages its own DOM, the source-mode plugin doesn't need to handle `figure`. Correct.

4. **`focus-mode-plugin.ts`:** Uses `node.isBlock && node.isTextblock` to find text blocks. Figure nodes are `atom: true`, so `node.isTextblock` would be false, and they would not get dimmed. This is actually a minor UX concern -- in focus mode, figure nodes would never be dimmed. However, this is an aesthetic choice, not a correctness issue. The plan's section 6b mentions source mode rendering but doesn't mention focus mode. This could be addressed as a follow-up.

5. **`selection-toolbar-plugin.ts`:** Walks up the node tree checking for `bullet_list`, `ordered_list`, `blockquote`, `code_block`. Figure nodes are atom nodes that don't contain a text cursor, so the toolbar would never appear while inside a figure. No change needed.

6. **`spellcheck-plugin.ts` extractSegments (line 130):** Uses `doc.descendants()` which visits all nodes. The `SKIP_NODE_TYPES` check at line 136 returns `false` to stop descending. Adding `'figure'` here is correct. Additionally, the check at line 150 (`!node.isBlock || node.isAtom || !node.inlineContent`) would also skip figure nodes because they are `isAtom === true`. So even without adding to SKIP_NODE_TYPES, spellcheck would skip figures. But adding it to SKIP_NODE_TYPES is cleaner because it prevents the initial descent.

**Verdict: Fix 6 is correct.** No other plugin node type lists need `'figure'` beyond what the plan already specifies. Minor note: focus mode dimming won't apply to figure nodes, but this is acceptable behavior.

---

## Overall Assessment

| Fix | Status | Confidence |
|-----|--------|------------|
| Fix 1: Export path | Correct | HIGH |
| Fix 2: Initial load metadata injection | Correct with documentation gap | HIGH |
| Fix 3: BlockType mapping | Correct | HIGH |
| Fix 4: Post-parse figure matching | Correct | HIGH |
| Fix 5: Remark plugin + figure node | Correct with documentation gaps | HIGH |
| Fix 6: spellcheck-plugin.ts | Correct | HIGH |

### Issues to address

**Important (should fix in plan):**

1. **Remark plugin paragraph unwrapping** (Fixes 2 and 5): The plan should explicitly document that the remark plugin must handle the mdast structure where images are children of paragraphs. In mdast, `![alt](media/file.png)` on its own line produces `root > paragraph > image`, not `root > image`. The remark plugin must detect paragraphs containing a single image child with `media/`-prefixed URL and replace the entire paragraph with a `figure` node. This is different from how `section-break-plugin.ts` works (where `html` nodes are already top-level in mdast). Without this, figure nodes would end up nested inside paragraphs, breaking the block-level assumption.

2. **Focus mode behavior** (Fix 6 adjacent): Figure nodes won't be dimmed in focus mode because `node.isTextblock` is false for atom nodes. This is probably fine for initial implementation but should be noted as a known behavior.

### No issues found

Fixes 1, 3, 4, and 6 are verified correct with no caveats. The export path is properly scoped to `DocumentManager.loadContentForExport()`. The BlockType mapping flows correctly through snapshot -> detectChanges -> inserts. Position-order matching for figure metadata injection handles all edge cases (0 images, mixed content). The spellcheck SKIP_NODE_TYPES addition is correct and complete -- no other plugins need `'figure'` in their type lists.
