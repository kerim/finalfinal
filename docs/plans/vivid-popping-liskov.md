# Merge Plan: cursor → main (Card Preview Drag Fix)

## Summary

Merge the `cursor` branch's AppKit-based drag preview fix into `main` while preserving all of main's recent work (project management features, section break fix, SwiftLint cleanup).

**Key insight**: cursor has 1 commit (drag preview blocking fix), main has 5 commits ahead. The conflict resolution strategy is to keep main's version/features and integrate cursor's DraggableCardView approach.

## Conflict Analysis

### 1. `OutlineSidebar.swift` - 3 conflict blocks

| Location | HEAD (main) | cursor | Resolution |
|----------|-------------|--------|------------|
| Line ~161 | `@State private var subtreeDragHintTimer: Timer?` | `@State private var subtreeDragHintTask: Task<Void, Never>?` | **Take cursor** - Task is better lifecycle management |
| Lines ~302-440 | SwiftUI `.draggable()` with `makeDragTransfer()`, `makeDragPreview()` | Uses `DraggableCardView` with AppKit | **Take cursor** - this IS the fix |
| Lines ~513-541 | Drop delegate handles ghost state | DraggableCardView handles ghost state | **Take cursor** - matches DraggableCardView approach |

**Critical**: cursor's approach replaces SwiftUI's `.draggable()` modifier with `DraggableCardView` (NSViewRepresentable) which uses AppKit's `beginDraggingSession()` for cursor offset control.

### 2. `project.yml` - Version conflict

| HEAD (main) | cursor | Resolution |
|-------------|--------|------------|
| `0.1.78` | `0.1.75` | **Keep 0.1.78** (main is ahead), then bump to **0.1.79** after merge |

### 3. `web/package.json` - Version conflict

| HEAD (main) | cursor | Resolution |
|-------------|--------|------------|
| `0.1.78` | `0.1.75` | **Keep 0.1.78**, then bump to **0.1.79** after merge |

### 4. `project.pbxproj` - 3 conflict blocks

| Location | HEAD (main) | cursor | Resolution |
|----------|-------------|--------|------------|
| Lines ~93-98 | Has `codemirror.html`, `codemirror.css`, `FileCommands.swift` refs | Doesn't have them | **Keep HEAD** - these are main's additions |
| Lines ~374-378 | `DocumentManager.swift in Sources` | `DraggableCardView.swift in Sources` | **Keep BOTH** - both files exist |
| Lines ~499-528 | Version `0.1.78` in build configs | Version `0.1.75` | **Keep HEAD** (`0.1.78`) |

## Step-by-Step Resolution

### Step 1: Resolve OutlineSidebar.swift

Accept cursor's changes for all 3 conflict blocks:
- Replace Timer with Task
- Use DraggableCardView instead of `.draggable()` modifier
- Simplify drop delegate callbacks (ghost state handled by DraggableCardView)

The key functional change is replacing:
```swift
.draggable(makeDragTransfer(for: section)) {
    makeDragPreview(for: section)
}
```

With:
```swift
DraggableCardView(
    section: section,
    allSections: filteredSections,
    isGhost: draggingSubtreeIds.contains(section.id),
    onDragStarted: { ... },
    onDragEnded: { ... },
    onSingleClick: { ... },
    onDoubleClick: { ... }
)
```

### Step 2: Resolve project.yml

Keep HEAD version (0.1.78):
```yaml
CURRENT_PROJECT_VERSION: "0.1.78"
```

### Step 3: Resolve web/package.json

Keep HEAD version (0.1.78):
```json
"version": "0.1.78"
```

### Step 4: Resolve project.pbxproj

1. **File references section (~93-98)**: Keep HEAD's additions (codemirror.html, codemirror.css, FileCommands.swift)
2. **Sources section (~374-378)**: Include BOTH files:
   ```
   49ACC632B2B50DFDBED9954B /* DocumentManager.swift in Sources */,
   5AF10728B84222571BDBB8A1 /* DraggableCardView.swift in Sources */,
   ```
3. **Build config sections (~499-528)**: Keep HEAD's version (0.1.78)

### Step 5: Post-merge Version Bump

After resolving conflicts, bump version to 0.1.79 in:
- `project.yml`
- `web/package.json`

Then regenerate Xcode project:
```bash
xcodegen generate
```

## Files Changed

| File | Action |
|------|--------|
| `OutlineSidebar.swift` | Merge - take cursor's DraggableCardView approach |
| `DraggableCardView.swift` | New file from cursor (already staged) |
| `project.yml` | Keep HEAD → bump to 0.1.79 |
| `web/package.json` | Keep HEAD → bump to 0.1.79 |
| `project.pbxproj` | Merge - keep all file refs, use HEAD's version |

## Verification

1. **Build check**: Run `xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build`
2. **Functional test**:
   - Drag a section card and verify preview appears to the RIGHT of cursor (not under it)
   - Test Option+drag for subtree drag (preview should show "+N" badge)
   - Verify drop indicators appear correctly
   - Test single-click (scroll to section) and double-click (zoom) still work
3. **Regression check**:
   - Verify existing drag-drop reordering works
   - Verify section status filtering works
   - Verify zoom in/out works
