# Code Review: Remove Upper Limit on Drag-Drop Heading Level

## Summary

The proposed change removes the upper constraint (shallower direction) on heading levels during drag-drop, allowing a section to jump from any deep level back to H1 in a single drag. Currently, dragging is constrained to predecessorLevel +/- 1. The change opens it to `1...predecessorLevel+1`.

I have reviewed all five files in the drag-drop pipeline plus the downstream section management and hierarchy enforcement code. Below are my findings.

---

## 1. What Was Done Well

- The plan correctly identifies `calculateZoneLevel()` as the single choke point for the drag-time level constraint.
- The proposed code removes the `max(1, predecessorLevel - 1)` floor and replaces it with `minLevel = 1`, which directly achieves the stated goal.
- The plan correctly notes that `ContentView+HierarchyEnforcement.swift` only enforces a ceiling (`headerLevel > maxLevel`), never a floor, so it will not undo the change.

---

## 2. Verification: No Other Constraint Points Override the Fix

I traced the full data flow from drag to persistence:

1. **`calculateZoneLevel()`** (OutlineSidebar+Models.swift:70) -- the ONLY place that constrains level during drag interaction. Both `SectionDropDelegate.dropUpdated()` and `EndDropDelegate.dropUpdated()` call this function and use its return value directly as `constrainedLevel`, which becomes the `level` in the `DropPosition` enum. No further clamping occurs in the drop delegates.

2. **`handleDrop()` / `handleDropAtEnd()`** (OutlineSidebar.swift:344, 384) -- these extract `position.level` and pass it unmodified as `newLevel` in the `SectionReorderRequest`. No clamping.

3. **`reorderSection()` -> `reorderSingleSection()` / `reorderSubtree()`** (ContentView+SectionManagement.swift:74-235) -- these apply `request.newLevel` directly. No clamping. The only check is `request.newLevel > 0`.

4. **`finalizeSectionReorder()`** (ContentView+SectionManagement.swift:238) -- calls `enforceHierarchyConstraints()` AFTER the move. This enforcement only clamps levels that are **too deep** (greater than predecessor + 1) and forces position 0 to be H1. It never raises a level that is "too shallow." So moving an H4 to H1 will not be overridden.

5. **`enforceHierarchyConstraintsStatic()`** and `hasHierarchyViolations()`** (ContentView+HierarchyEnforcement.swift:51-116) -- confirmed: both only check `section.headerLevel > maxLevel`. There is no `minLevel` check. The plan's claim is correct.

**Verdict: The proposed change in a single file is sufficient. No other code path re-constrains the level in the shallower direction.**

---

## 3. Visual Feedback Code

The `DropIndicatorLine` (OutlineSidebar+Components.swift:41) receives the `level` from `DropPosition` and displays `DragLevelBadge` which renders `#` characters corresponding to the level. This code handles any level from 1 upward (including H7+ with the `######+N` notation). **No changes needed here.**

The drop indicator overlays in `OutlineSidebar.swift` (lines 217-231) pass the level from the `DropPosition` directly. **No changes needed.**

---

## 4. Bugs and Issues in the Proposed Code

### 4a. IMPORTANT: Division by zero when predecessorLevel == 0

The proposed code:
```swift
let minLevel = 1
let maxLevel = predecessorLevel + 1
let levels = Array(minLevel...maxLevel)
```

This path is unreachable when `predecessorLevel == 0` because of the early return at line 72-74 (`if predecessorLevel == 0 { return 1 }`). However, the current code has the same guard, so this is safe. **No bug here** -- but worth confirming the guard remains in the final code.

### 4b. No bugs in range/index arithmetic

When `predecessorLevel >= 1`:
- `minLevel = 1`, `maxLevel = predecessorLevel + 1`
- `levels = Array(1...predecessorLevel+1)`, which always has at least 2 elements (when predecessorLevel == 1: `[1, 2]`)
- `zoneWidth = sidebarWidth / CGFloat(levels.count)` -- always positive since `sidebarWidth` is tracked via `onGeometryChange` and has a `minWidth: 250` constraint
- `zoneIndex = min(Int(x / zoneWidth), levels.count - 1)` -- clamped to valid upper bound
- `return levels[max(0, zoneIndex)]` -- clamped to valid lower bound

**No off-by-one or negative index issues.** The `max(0, ...)` guard handles the edge case where `x` is negative (which can happen with coordinate transforms in AppKit-wrapped views).

### 4c. Potential issue: negative x values

If `x` is negative, `Int(x / zoneWidth)` will be negative. The `max(0, zoneIndex)` clamp handles this correctly, mapping it to `levels[0]` which is 1 (H1). **Safe.**

---

## 5. UX Concern: Many Narrow Zones for Deep Headers

This is the most significant concern with the proposal.

**Current behavior (predecessorLevel +/- 1):** Always 2-3 zones. With a 300px sidebar, zones are 100-150px wide. Easy to target.

**Proposed behavior (1...predecessorLevel+1):**

| Predecessor Level | Number of Zones | Zone Width (300px sidebar) |
|---|---|---|
| H1 | 2 zones | 150px |
| H2 | 3 zones | 100px |
| H3 | 4 zones | 75px |
| H4 | 5 zones | 60px |
| H5 | 6 zones | 50px |
| H6 | 7 zones | ~43px |
| H7+ | 8+ zones | <38px |

For H4 predecessors (common in academic writing with Chapter > Section > Subsection > Paragraph), 5 zones at 60px each is still usable but noticeably tighter than the current 100px zones. For H5+ predecessors, zones become quite narrow and could be frustrating to target precisely during a drag operation.

**Suggestion:** Consider capping the number of zones at something like 5-6, and grouping the shallower levels. For example, the leftmost zone could cover H1, the next zone H2, etc., but beyond 5 zones, start grouping. Alternatively, a logarithmic or proportional zone sizing could give more space to the "same level" and "one deeper" zones (the most common targets) while still allowing access to shallower levels.

That said, **this is a UX judgment call, not a correctness bug.** The code will function correctly with narrow zones. If deep headers are rare in practice for this app's users, this may be perfectly acceptable. I would recommend testing with a real document that has H4+ sections to see how the zones feel.

---

## 6. Additional Observation: Subtree Drag Level Delta

In `reorderSubtree()` (ContentView+SectionManagement.swift:160), the `levelDelta` is computed as `request.newLevel - oldLevel`. With the expanded range, this delta could now be large (e.g., moving an H5 to H1 gives `levelDelta = -4`). All children in the subtree get this delta applied:

```swift
let newSectionLevel = section.headerLevel + levelDelta
```

If the root was H5 with children at H6 and H7, moving root to H1 would make children H2 and H3. This is the correct and expected behavior -- the relative hierarchy within the subtree is preserved. **No issue here.**

However, note that there is no clamping of `newSectionLevel` to >= 1 for children. If a child's level was somehow lower than the delta magnitude (unusual but theoretically possible with malformed data), it could go to 0 or negative. The `enforceHierarchyConstraints()` call in `finalizeSectionReorder()` would catch this, so it is not a practical risk, but worth noting.

---

## 7. Final Assessment

| Category | Verdict |
|---|---|
| Correctness | The single-file change achieves the stated goal |
| No missed constraint points | Confirmed -- no other code re-clamps the level floor |
| Hierarchy enforcement compatibility | Compatible -- enforcement only clamps ceiling |
| Visual feedback | Works without changes |
| Bugs in proposed code | None found |
| UX concern with many zones | Moderate -- worth testing with deep headers |

### Recommendation

The proposed change is **safe to implement**. The only consideration is whether the UX of many narrow zones at deep heading levels is acceptable. I recommend:

1. Implement the change as proposed.
2. Test with a document containing H4+ sections to evaluate zone targeting comfort.
3. If zones feel too narrow at deep levels, consider a follow-up improvement such as:
   - Cap zones at 5 and group shallow levels into a single wide zone
   - Use non-uniform zone widths (wider for "same level" and "one deeper")
   - Add a visual guide showing zone boundaries during drag
