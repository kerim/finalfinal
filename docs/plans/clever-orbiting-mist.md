# Fix drag-drop heading level upper limit

## Context

When dragging sections in the outline sidebar, the heading level is constrained to predecessorLevel +/- 1. This means dropping after an H4 only allows H3, H4, or H5. The +1 limit (going deeper) is correct — you can't skip a level going down. But the -1 limit (going shallower) is wrong — it's valid to jump from H4 back to H1 in a document hierarchy.

The hierarchy enforcement code (`ContentView+HierarchyEnforcement.swift`) already permits this — it only checks `headerLevel > maxLevel` (can't skip deeper), not a minimum. The constraint is purely in the drag-drop zone calculation.

**Validated by 3 independent code reviewers:** No other constraint points exist in the drag pipeline. The level from `calculateZoneLevel()` flows unmodified through drop delegates, drop handlers, and reorder requests. Visual indicators (`DragLevelBadge`) already handle arbitrary levels.

## Change

**Single file:** `final final/Views/Sidebar/OutlineSidebar+Models.swift` — `calculateZoneLevel()` (line 70)

Change `minLevel` from `max(1, predecessorLevel - 1)` to `1`, and replace the 2-or-3 zone `Set` logic with a dynamic array of all available levels:

```swift
/// Calculate target header level from horizontal drop position using zone-based selection
/// Returns a level from 1 to predecessorLevel+1 based on x position within the sidebar
func calculateZoneLevel(x: CGFloat, sidebarWidth: CGFloat, predecessorLevel: Int) -> Int {
    // Special case: first position (no predecessor) only allows level 1
    if predecessorLevel == 0 {
        return 1
    }

    let minLevel = 1
    let maxLevel = predecessorLevel + 1

    // All available levels from H1 to one deeper than predecessor
    let levels = Array(minLevel...maxLevel)

    // Divide sidebar width evenly among levels
    let zoneWidth = sidebarWidth / CGFloat(levels.count)
    let zoneIndex = min(Int(x / zoneWidth), levels.count - 1)
    return levels[max(0, zoneIndex)]
}
```

Zone layout examples (assuming ~300px sidebar):

| Predecessor | Zones | Width each |
|---|---|---|
| H1 | H1 \| H2 | 150px |
| H2 | H1 \| H2 \| H3 | 100px |
| H3 | H1 \| H2 \| H3 \| H4 | 75px |
| H4 | H1 \| H2 \| H3 \| H4 \| H5 | 60px |

No changes needed to `ContentView+HierarchyEnforcement.swift` — it only enforces max level (predecessor+1, capped at H6), never a minimum.

## Verification

1. Build: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
2. Open a document with sections at various heading levels
3. Drag after an H4 section — verify you can drop as H1, H2, H3, H4, or H5 by moving horizontally
4. Drag after an H1 section — verify options are still H1 and H2 only
5. Confirm hierarchy enforcement still clamps sections that skip levels going deeper
6. Check drag level badge displays correct level during drag
