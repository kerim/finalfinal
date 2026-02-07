# Sidebar Disappears When Switching to CodeMirror and Zooming

## Summary

When the user switched to CodeMirror (source mode) and zoomed into a section, the sidebar would go blank — all section cards disappeared. The root cause was that `replaceBlocks()` (used on the first zoom path) generated new UUIDs for every block, invalidating the `zoomedSectionIds` set that the sidebar used to filter visible sections. The fix added title-based ID preservation to `replaceBlocks()` (matching the pattern already in `replaceBlocksInRange()`) and hardened all abort paths in `zoomToSection()` to clean up zoom state.

## Reproduction Steps

1. Open a project with multiple sections (headings)
2. Switch to Source mode (CodeMirror) via Cmd+/
3. Double-click a section card in the sidebar to zoom into it
4. Observe: the sidebar goes blank — no section cards are shown

## Root Cause Analysis

The failure followed a 10-step chain:

1. User double-clicks a section card → `zoomToSection()` is called
2. `zoomToSection()` calls `flushCodeMirrorSyncIfNeeded()` to persist any pending edits
3. On the first zoom, `zoomedBlockRange` is nil, so the flush takes the `else` branch
4. The `else` branch calls `replaceBlocks()` (full document re-parse)
5. `replaceBlocks()` deletes all existing blocks and inserts new ones
6. Each new block gets a fresh UUID — no ID preservation from existing blocks
7. The section that was zoomed into now has a different UUID than when `zoomToSection()` started
8. `zoomedSectionIds` was computed from the old UUIDs (before the flush)
9. The sidebar filters sections by `zoomedSectionIds` — none of the new UUIDs match
10. Sidebar renders empty

## Fix Timeline

### Phase 1: Block Architecture Foundation (Feb 5, `dd6842d`)

Merged the block-based architecture branch. Introduced:
- Block model with CRUD operations in `Database+Blocks.swift`
- `replaceBlocks()` for full-document re-parsing
- `BlockParser` to convert markdown into block records

At this stage, every call to `replaceBlocks()` generated entirely new UUIDs. No ID preservation existed.

### Phase 2: Zoom & Pseudo-Section Fixes (Feb 5, `95d22eb`)

- `getDescendantIds()` switched from a parentId-only traversal to a document-order algorithm
- Pseudo-sections (content separated by `§` breaks without headings) were now included in zoom via sortOrder scan

This fixed zoom scope but did not address ID stability.

### Phase 3: Status Persistence & Watchdog (Feb 6, `681a65f`)

- Added `contentState` watchdog with a 5-second timeout to prevent stuck non-idle states
- Introduced `syncZoomedSections()` to handle insertions and deletions while zoomed
- `zoomedSectionIds` updated dynamically via `onZoomedSectionsUpdated` callback

This made zoom state reactive but still depended on IDs being stable across re-parses.

### Phase 4: Block Sort Order Integrity (Feb 6, `105f564`)

- Created `replaceBlocksInRange()` for partial (zoomed) re-parses
- Added `idByTitle` + `metadataByTitle` lookups to `replaceBlocksInRange()` — existing section IDs and metadata (status, tags, wordGoal, goalType) were preserved across re-parses
- Sort order normalization added inside `replaceBlocksInRange()`
- `contentState` set BEFORE flush in `zoomToSection()` to prevent observation race conditions
- Fallback heading lookup in `flushCodeMirrorSyncIfNeeded()` for renamed headings

**This fixed zoomed CM edits but missed the first-zoom path**, which calls `replaceBlocks()` (not `replaceBlocksInRange()`).

### Phase 5: The Actual Fix (Feb 7, `4c6de6d`)

Two changes completed the fix:

**Fix A: ID preservation in `replaceBlocks()`** — Added the same `idByTitle` + `metadataByTitle` pattern from `replaceBlocksInRange()` to the full-document `replaceBlocks()`. Existing sections now retain their UUIDs and metadata even through a full re-parse.

**Fix B: Zoom abort hardening** — Four abort/error paths in `zoomToSection()` were fixed:
- Moved `zoomedSectionIds` computation to AFTER the DB guard (so it's never set if DB access fails)
- Added zoom state cleanup (`zoomedSectionIds = nil`, `zoomedSectionId = nil`, `zoomedBlockRange = nil`) to:
  - The sections guard (no sections found)
  - The DB guard (database unavailable)
  - The catch block (any thrown error)
  - The watchdog timeout handler

## Key Insight

Phase 4 didn't fully fix the bug because `replaceBlocksInRange()` is only used when `zoomedBlockRange` is already set — i.e., when the user is *already* zoomed and makes an edit. The *first* zoom in CodeMirror mode has no prior `zoomedBlockRange`, so `flushCodeMirrorSyncIfNeeded()` takes the `else` branch and calls `replaceBlocks()`. That function had no ID preservation until Phase 5. The fix was applying the same title-based preservation pattern to both code paths.

### Phase 6: Annotation Sidebar Restoration on CM Zoom-Out (Feb 7)

**Problem:** When exiting zoom in CodeMirror mode, the annotation sidebar only showed annotations from the previously zoomed section instead of all annotations from the full document.

**Root cause:** During zoom, if the user edits, `annotationSyncService.contentChanged()` runs with zoomed-only content. The reconciliation deletes DB annotations not found in the zoomed subset. On zoom-out, Milkdown normalizes markdown which triggers `onChange` → annotation sync re-creates all annotations. CodeMirror returns content verbatim → no change detected → annotation sync never fires → deleted annotations stay deleted.

**Fix:** Added `annotationSyncService.contentChanged(editorState.content)` in the `.didZoomOut` notification handler in `ContentView.swift`, before the existing bibliography sync. At notification time, `contentState` is already `.idle` and `editorState.content` has the full document. The call is idempotent for Milkdown (which already re-syncs via its own `onChange` path).

**File:** `ContentView.swift` — `.onReceive(.didZoomOut)` handler

## What Remains Broken

Per the Phase 5 commit message (`4c6de6d`):

- **Bibliography broken in both editors** — Bibliography generation/rendering has separate issues in both Milkdown and CodeMirror

## Files Modified

| File | Key Changes |
|------|------------|
| `Database+Blocks.swift` | `replaceBlocks()` with `idByTitle`/`metadataByTitle` preservation; `replaceBlocksInRange()` with same pattern plus sort order normalization |
| `EditorViewState.swift` | `contentState` state machine; watchdog timer; zoom abort hardening on all guard/catch paths; `flushCodeMirrorSyncIfNeeded()` with fallback heading lookup |
| `ContentView.swift` | Wiring for `onZoomedSectionsUpdated` callback; contentState management during editor lifecycle events; annotation re-sync on zoom-out |

## Architectural Patterns Established

**Title-based ID preservation:** Before deleting blocks, build an `idByTitle` dictionary from existing heading blocks. After re-parsing, reassign the old UUID to any new block whose title matches. First-match-wins, consume after use (to handle duplicate headings correctly).

**Metadata preservation:** Same consume-after-use pattern for status, tags, wordGoal, and goalType. Build `metadataByTitle` before delete, apply on insert.

**contentState before flush:** Set the transitional `contentState` (e.g., `.zooming`) *before* any operation that triggers database writes. This blocks ValueObservation from firing during the transition, preventing race conditions where the sidebar sees intermediate DB states.

**Zoom state cleanup on all abort paths:** Every guard statement, catch block, or early return in `zoomToSection()` must nil out `zoomedSectionIds`, `zoomedSectionId`, and `zoomedBlockRange`. Failing to do so leaves the sidebar in a filtered state with no valid filter set, resulting in a blank sidebar.
