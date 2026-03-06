# Block Sync Patterns

Patterns for block-level sync and sidebar zoom filtering. Consult before modifying block sync or zoom scope code.

---

## Pseudo-Sections Have parentId=nil (Use Document Order Instead)

**Problem:** When double-clicking a section to zoom, pseudo-sections (content breaks marked with `<!-- ::break:: -->`) that visually belonged to the zoomed section were not included. For example, zooming into `# Introduction` didn't include the pseudo-section that followed it.

**Root Cause:** Pseudo-sections are stored with H1 header level (inherited from the preceding actual header), which means they have `parentId = nil`. The `getDescendantIds()` method used `parentId` to find children:

```swift
// BROKEN: Misses pseudo-sections because they have parentId=nil
for section in sections where section.parentId != nil && ids.contains(section.parentId!) {
    ids.insert(section.id)
}
```

Even though the pseudo-section follows `# Introduction` in the document, there's no parent-child relationship in the data model.

**Solution:** Use **document order** (sortOrder) to find pseudo-sections that belong to a regular section. A pseudo-section "belongs to" the regular section that immediately precedes it, until hitting another regular section at the same or shallower level:

```swift
private func getDescendantIds(of sectionId: String) -> Set<String> {
    var ids = Set<String>([sectionId])
    let sortedSections = sections.sorted { $0.sortOrder < $1.sortOrder }

    guard let rootIndex = sortedSections.firstIndex(where: { $0.id == sectionId }),
          let rootSection = sortedSections.first(where: { $0.id == sectionId }) else {
        return ids
    }
    let rootLevel = rootSection.headerLevel

    // First: Add pseudo-sections by document order
    for i in (rootIndex + 1)..<sortedSections.count {
        let section = sortedSections[i]

        // Stop at a regular (non-pseudo) section at same or shallower level
        if !section.isPseudoSection && section.headerLevel <= rootLevel {
            break
        }

        // Include pseudo-sections (they visually belong to the preceding section)
        if section.isPseudoSection {
            ids.insert(section.id)
        }
    }

    // Second: Add all transitive children by parentId (runs AFTER pseudo-sections added)
    var changed = true
    while changed {
        changed = false
        for section in sortedSections where section.parentId != nil && ids.contains(section.parentId!) {
            if !ids.contains(section.id) {
                ids.insert(section.id)
                changed = true
            }
        }
    }

    return ids
}
```

**Key insight:** The `parentId`-based loop runs AFTER pseudo-sections are added, so it picks up all transitive children of pseudo-sections (the pseudo-section's children have `parentId` pointing to the pseudo-section).

**General principle:** When parent-child relationships don't capture all logical groupings (like pseudo-sections inheriting H1 level), fall back to document order for ownership determination.

---

## Sidebar Must Use Same Zoom IDs as Editor

**Problem:** When zoomed into a pseudo-section with shallow mode, the sidebar still showed `## History` which shouldn't be visible. The editor showed correct content.

**Root Cause:** The sidebar had its own `filterToSubtree()` method that recalculated descendants using `parentId`. This created a mismatch with EditorViewState's `zoomedSectionIds`, which used the fixed document-order algorithm.

```swift
// OutlineSidebar - BROKEN: recalculates using parentId only
private func filterToSubtree(sections: [SectionViewModel], rootId: String) -> [SectionViewModel] {
    var idsToInclude = Set<String>([rootId])
    for section in sections where section.parentId != nil && idsToInclude.contains(section.parentId!) {
        // Misses pseudo-sections, same bug as before
    }
}
```

**Solution:** Pass `zoomedSectionIds` from EditorViewState to OutlineSidebar as a read-only property, and use it directly instead of recalculating:

```swift
// OutlineSidebar - FIXED: uses EditorViewState's pre-calculated IDs
struct OutlineSidebar: View {
    let zoomedSectionIds: Set<String>?  // Read-only, from EditorViewState

    private var filteredSections: [SectionViewModel] {
        var result = sections

        // Apply zoom filter using zoomedSectionIds from EditorViewState
        if let zoomedIds = zoomedSectionIds {
            result = result.filter { zoomedIds.contains($0.id) }
        }
        // ...
    }
}
```

Then remove the now-unused `filterToSubtree()` method entirely.

**General principle:** When multiple components need to filter/display the same subset of data, compute the filter criteria once in the source-of-truth (EditorViewState) and share it, rather than having each component recalculate independently. Independent recalculation leads to subtle mismatches.

---

## Shift Subsequent Blocks When Inserts Overflow a Sort-Order Range

**Problem:** When replacing blocks in a sort-order range `[start, end)`, the new block count can exceed the original count. Blocks are assigned sequential sort orders starting at `start`, so if `start + newCount > end`, the new blocks collide with existing blocks after the range. This caused duplicate headings when zooming out after creating headings in a zoomed CodeMirror view.

**Root Cause:** `replaceBlocksInRange()` deleted old blocks in the range and inserted new ones with sort orders `start, start+1, ..., start+N-1`. When N > (end - start), sort orders overflowed into the space occupied by subsequent blocks. Two blocks sharing the same sort order produced duplicates.

**Solution:** Before inserting, check whether the new blocks will overflow the range. If so, shift all blocks at or after `end` forward by the overflow amount:

```swift
// In replaceBlocksInRange(), between delete and insert:
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

**General principle:** When inserting N items into a range that originally held M items (N > M), always shift subsequent items to make room. Don't assume the gap between the range boundaries is large enough — ranges are often tight (one sort order per block), and any overflow causes collisions. This applies to any ordered collection where items are addressed by position (sort orders, indices, display orders).

---

## Caption Comments Must Stay Grouped with Their Image in BlockParser

**Problem:** Images with `<!-- caption: text -->` comments duplicated on each content roundtrip (edit → save → reload). After several roundtrips, multiple copies of the caption appeared as standalone paragraph blocks.

**Root Cause:** The Milkdown `toMarkdown` serializer emits the caption as a separate block-level `html` mdast node before the `paragraph > image` node. Remark-stringify inserts a blank line between block-level siblings:

```markdown
<!-- caption: text -->

![alt](media/file.png)
```

Swift's `splitIntoRawBlocks()` splits on blank lines, creating two blocks:
- Block A: `<!-- caption: text -->` → classified as `.paragraph`
- Block B: `![alt](media/file.png)` → classified as `.image`

The caption paragraph block persists in the database. On each roundtrip, the caption exists in two places: as Block A (standalone paragraph) and embedded in the figure node's `caption` attribute. This accumulates over roundtrips.

**Solution:** Follow the same continuation pattern used for footnote definitions. In `splitIntoRawBlocks()`, when the current block is a caption comment and the next non-blank line starts with `![`, absorb the blank line to keep caption and image in the same block:

```swift
// After footnote def check, before block flush:
let trimmedBlock = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
if trimmedBlock.range(of: "^<!--\\s*caption:", options: .regularExpression) != nil
   && trimmedBlock.hasSuffix("-->") {
    var nextIdx = index + 1
    while nextIdx < lines.count
          && lines[nextIdx].trimmingCharacters(in: .whitespaces).isEmpty {
        nextIdx += 1
    }
    if nextIdx < lines.count
       && lines[nextIdx].trimmingCharacters(in: .whitespaces).hasPrefix("![") {
        currentBlock += line + "\n"
        continue
    }
}
```

Also add a `detectBlockType` case for combined caption+image blocks (classify as `.image`).

**General principle:** When an upstream serializer emits logically-connected content as separate block-level nodes with blank lines between them, the block parser must recognize the pattern and keep the pieces together. The footnote continuation pattern (peek ahead for continuation lines) is reusable for any multi-line construct that remark-stringify splits apart.

---

## Surgical Updates Beat Full-Document Replacement

**Problem:** Hierarchy enforcement (adjusting child heading levels when a parent heading changes level) caused content to disappear, reshuffle, and duplicate. The enforcement read ALL blocks from DB, assembled markdown via `BlockParser.assembleMarkdown()`, and replaced the entire editor document via `setContentWithBlockIds()`.

**Root Cause:** DB markdown assembly (`markdownFragments.joined(separator: "\n\n")`) differs from ProseMirror serialization by small amounts (e.g., 58 chars in testing). When the assembled markdown replaces the editor document, the diff causes block-sync to detect spurious changes, leading to cascading data corruption.

**Solution:** Instead of replacing the document, compute only what changed and apply it surgically:

1. Save original heading levels before enforcement
2. Run enforcement (modifies sections array)
3. Diff: which headings actually changed level?
4. **WYSIWYG mode**: Call `updateHeadingLevels([{blockId, newLevel}])` which uses ProseMirror's `setNodeMarkup()` to change only the `level` attribute — no document replacement, no content shift
5. **Source mode fallback**: String replacement of heading prefixes (`### ` → `## `) with forward-cursor matching to handle duplicate titles

**Key implementation details:**
- `updateHeadingLevels()` pauses sync and content push timer (`setSyncPaused`, `setIsSettingContent`) during the operation
- After surgery, `setCurrentContent(getMarkdown())` updates JS-side content cache
- `resetAndSnapshot()` rebuilds the baseline so the next poll sees no false changes
- `.blockSyncDidPushContent` notification syncs Swift-side `lastPushedContent` to prevent redundant `updateNSView` pushes

**General principle:** When only a few attributes need to change, prefer surgical ProseMirror operations (`setNodeMarkup`, `setNodeType`) over full document replacement. The DB-to-editor round-trip introduces serialization discrepancies that accumulate into data corruption. Compute the minimal diff and apply it directly.

---

## Markdown Re-Parsing Loses Non-Markdown Attributes

**Problem:** Image widths reverted to full width when switching editors or whenever `updateNSView` triggered a `setContent()` push.

**Root Cause:** `setContent(markdown)` re-parses the markdown string into ProseMirror nodes. Markdown `![alt](src)` does NOT encode `width` or `blockId` — these are ProseMirror node attributes stored only in the editor's document tree. Re-parsing creates fresh figure nodes with `width: null` and `blockId: ''` (schema defaults).

**Solution:** In `setContent()`, capture figure attributes before document replacement and restore them after:

1. Before `tr.replace()`: Walk existing doc, save `{src, width, blockId}` for each figure node
2. After `view.dispatch(tr)`: Walk new doc, restore attributes by positional matching with `src` verification
3. Move `resetAndSnapshot()` to AFTER restoration so the sync baseline includes restored attributes

This follows the same positional-matching-with-src-verification pattern used by `applyBlocks()` and `setContentWithBlockIds()` for their image metadata injection.

**General principle:** Any node attribute that is not serialized to/from markdown will be lost on re-parse. When programmatically replacing document content, explicitly preserve and restore non-markdown attributes. Use positional matching with a content-based key (like `src`) to map old nodes to new nodes.

---

## Collapse Consecutive List Block IDs for ProseMirror Alignment

**Problem:** Clicking `# Notes` (or any section near the end of a document with lists) in the outline sidebar didn't scroll in Milkdown. Worked in CodeMirror and for earlier sections.

**Root Cause:** Swift's `BlockParser.splitIntoRawBlocks` splits on blank lines, creating separate blocks per list item. `assembleMarkdown` rejoins with `\n\n`. When ProseMirror parses the result, consecutive same-type list items merge into a single `bullet_list` or `ordered_list` node.

`setBlockIdsForTopLevel` assigns IDs sequentially — e.g., 108 DB blocks but only 97 PM nodes. The first 97 get IDs, the last 11 (including `# Notes` at the end) are dropped. `scrollToBlock` then fails because the block ID isn't in the map.

**Solution:** `BlockParser.idsForProseMirrorAlignment(_:)` collapses consecutive same-type list block IDs before sending them to JS:

```swift
static func idsForProseMirrorAlignment(_ blocks: [Block]) -> [String] {
    var ids: [String] = []
    var prevListType: BlockType? = nil
    for block in blocks {
        let isListBlock = (block.blockType == .bulletList || block.blockType == .orderedList)
        if isListBlock && block.blockType == prevListType {
            continue  // PM merges this with previous list node
        }
        ids.append(block.id)
        prevListType = isListBlock ? block.blockType : nil
    }
    return ids
}
```

Used in `fetchBlocksWithIds()`, `pushBlockIds()`, and `setContentWithBlockIds()` — anywhere Swift sends block IDs to JS.

**Known limitation:** Between an incremental block-sync UPDATE and the next `flushContentToDatabase()`, the DB may have duplicated list content (first block = all items, remaining blocks = stale individual items). This is benign because `flushContentToDatabase()` runs at all major transitions and the editor always has the canonical content.

**General principle:** When the block parser creates more blocks than ProseMirror creates top-level nodes (due to node merging), the ID array must be collapsed to match PM's count. This affects list items (consecutive same-type lists merge) but not headings, paragraphs, figures, blockquotes, or code blocks (all 1:1 with PM).
