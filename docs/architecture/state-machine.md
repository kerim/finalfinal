# State Machine, Zoom, and Hierarchy

Content state machine, zoom functionality, hierarchy constraints, ValueObservation reactivity, and drag-drop reordering.

---

## Content State Machine

`EditorContentState` prevents race conditions during complex transitions:

```swift
enum EditorContentState {
    case idle                 // Normal operation
    case zoomTransition       // Zooming in/out of a section
    case hierarchyEnforcement // Fixing header level violations
    case bibliographyUpdate   // Auto-bibliography being regenerated
    case editorTransition     // Switching between Milkdown <-> CodeMirror
    case dragReorder          // During sidebar drag-drop reorder
}
```

**Guards**: SectionSyncService, BlockSyncService, and ValueObservation skip updates when `contentState != .idle`, preventing feedback loops.

**Cancellation Pattern**: `EditorViewState.currentPersistTask` stores the current persist task during drag-drop reorder. Rapid successive reorders cancel the previous persist task before starting a new one, preventing stale writes.

**Watchdog**: A `didSet` observer on `contentState` starts a 5-second watchdog Task whenever the state enters a non-idle value. If the state hasn't returned to `.idle` within 5 seconds, the watchdog force-resets it and cleans up associated state (e.g., `isZoomingContent`, pending continuations). This prevents permanently blocked ValueObservation if a transition is interrupted.

---

## Zoom Functionality

Double-clicking a sidebar section "zooms" into it:

1. **Zoom In** (block-based):
   - Finds the heading block, determines its sort-order range based on zoom mode:
     - **Full zoom**: from heading's sortOrder to next same-or-higher-level heading's sortOrder (includes all children)
     - **Shallow zoom**: from heading's sortOrder to the very next heading of any level (section's own content only)
   - Filters blocks within that range from the database
   - Assembles markdown from the filtered blocks
   - Records `zoomedSectionIds` and `zoomedBlockRange`
   - Pushes content + block IDs to editor via `setContentWithBlockIds()`
   - No `fullDocumentBeforeZoom` needed -- DB always has the complete document

2. **Zoom Out** (block-based):
   - Fetches ALL blocks from DB and assembles full document via `BlockParser.assembleMarkdown()`
   - No merge needed -- BlockSyncService writes changes to DB during zoom
   - Clears zoom state (`zoomedSectionIds`, `zoomedBlockRange`)
   - Pushes full content + block IDs to editor

**Sync While Zoomed**: BlockSyncService continues its 300ms polling during zoom. Changes are written directly to the block table. The `zoomedBlockRange` on EditorViewState tells `pushBlockIds()` which blocks to filter for the editor.

**Zoom Modes** (affects both sidebar and editor content):
- **Full zoom** (double-click): Sidebar shows section + all descendants (by `parentId`) + following pseudo-sections (by document order). Editor shows all content up to the next same-or-higher-level heading.
- **Shallow zoom** (Option+double-click): Sidebar shows section + only direct pseudo-sections (no children). Editor shows only the section's own body content, stopping at the very next heading of any level.

**Pseudo-Section Handling**: Pseudo-sections have `parentId = nil` (they inherit H1 level), so `parentId`-based traversal misses them. The `getDescendantIds()` method uses **document order** to find pseudo-sections:

1. Start from the zoomed section's position in sorted sections
2. Scan forward, collecting pseudo-sections until hitting a regular section at same or shallower level
3. Then run the `parentId`-based loop to collect all transitive children (including children of pseudo-sections)

**Sidebar Zoom Filter**: The sidebar uses `zoomedSectionIds` from EditorViewState directly (passed as a read-only property), rather than recalculating descendants. This ensures editor and sidebar show exactly the same sections.

---

## Hierarchy Constraints

Headers must follow a valid hierarchy (can't jump from H1 to H4):

- First section must be H1
- Each section's level <= predecessor's level + 1
- Violations are auto-corrected by demoting headers

`enforceHierarchyConstraints()` runs after section updates from database observation.

---

## Database Reactivity (ValueObservation)

GRDB's `ValueObservation` provides reactive updates. The observation now watches the **block table** (outline blocks only) instead of the sections table:

```swift
func startObserving(database: ProjectDatabase, projectId: String) {
    self.projectDatabase = database
    self.currentProjectId = projectId

    observationTask = Task {
        for try await outlineBlocks in database.observeOutlineBlocks(for: projectId) {
            guard !isObservationSuppressed else { continue }
            guard contentState == .idle else { continue }

            var viewModels = outlineBlocks.map { SectionViewModel(from: $0) }

            // Section-only word counts (own content, not children)
            for i in viewModels.indices {
                if let wc = try? database.sectionOnlyWordCount(blockId: viewModels[i].id) {
                    viewModels[i].wordCount = wc
                }
                // Aggregate word count (only when aggregate goal is set)
                if viewModels[i].aggregateGoal != nil {
                    if let awc = try? database.wordCountForHeading(blockId: viewModels[i].id) {
                        viewModels[i].aggregateWordCount = awc
                    }
                }
            }

            sections = viewModels
            recalculateParentRelationships()
            onSectionsUpdated?()
        }
    }
}
```

**Key details**:
- `observeOutlineBlocks(for:)` filters to heading + pseudo-section blocks only, without `.removeDuplicates()` — this allows word count updates to propagate even when heading blocks haven't changed (see [word-count.md](../architecture/word-count.md#zoom-mode-word-count-update))
- `SectionViewModel(from: Block)` converts block data to sidebar view models
- `sectionOnlyWordCount(blockId:)` counts words in the section's own content (to next heading of any level)
- `wordCountForHeading(blockId:)` aggregates words including descendants (only computed when `aggregateGoal` is set)
- `projectDatabase` and `currentProjectId` are stored on EditorViewState for use during zoom and reorder operations

**Suppression**: `isObservationSuppressed` is set during drag-drop operations to prevent database updates from overwriting in-progress reordering.

---

## Section Drag-Drop Reordering

The sidebar supports drag-drop reordering with hierarchy preservation:

1. **Single Section**: Section moves; orphaned children are promoted to parent's level
2. **Subtree Drag**: Section + all descendants move together; levels shift by delta

**Process** (block-based):
1. Set `contentState = .dragReorder`
2. Cancel `currentPersistTask` (from any rapid preceding reorder)
3. Reorder sections array in memory for immediate visual feedback
4. Recalculate parent relationships and enforce hierarchy constraints
5. Rebuild document content via `rebuildDocumentContentStatic()` (static method, no state mutation)
6. Push content to editor
7. Persist atomically via `reorderAllBlocks()` -- moves body blocks with their headings, applies heading updates (markdownFragment + headingLevel) in a single write transaction
8. Fire-and-forget `persistReorderedBlocks_legacySections()` for section table dual-write
9. Push block IDs to editor via `blockSyncService.pushBlockIds()`
10. Return to `contentState = .idle`

**Cancellation**: `currentPersistTask` on `EditorViewState` stores the async persist task. Rapid successive reorders cancel the previous task before starting a new one, preventing stale sort orders from being written.
