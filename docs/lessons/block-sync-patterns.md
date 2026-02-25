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
