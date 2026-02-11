# Block-Based Architecture

This document describes the target architecture for the app's content system after migrating from sections to blocks. It is not an implementation plan -- it describes how the parts fit together in the final state.

## Data Model

The database has one primary content table: `block`.

Each block is a structural element in the document: a paragraph, heading, code block, list, blockquote, table, section break, or bibliography entry. Every block has:

- A **stable UUID** that persists for the block's lifetime
- A **fractional sort order** (`Double`) that determines document position
- A **block type** and optional **heading level**
- The block's **markdown fragment** (its raw markdown text)
- The block's **plain text content** (for search and word count)
- Optional **section metadata** (status, tags, word goal) -- only meaningful on heading and section-break blocks

Blocks use fractional sort order so that inserting a new block between two existing blocks (e.g., sortOrder 5.0 and 6.0) just assigns 5.5 -- no renumbering of other blocks required.

## System Components

```
+------------------+       +------------------+
|    Milkdown      |       |    CodeMirror     |
|   (WYSIWYG)      |       |    (Source)        |
|                  |       |                  |
| ProseMirror      |       | Plain text with   |
| block-tracking   |       | <!-- @bid:UUID -->|
| plugin           |       | anchors           |
+--------+---------+       +--------+---------+
         |                          |
         | BlockChanges             | Markdown with anchors
         | (structured diffs)       | (extract IDs on sync)
         |                          |
+--------+--------------------------+---------+
|              BlockSyncService               |
|                                             |
|  Receives block changes from both editors.  |
|  Writes to block table. Confirms new IDs.   |
+---------------------+-----------------------+
                      |
                      | GRDB read/write
                      |
+---------------------+-----------------------+
|              Block Table (SQLite)            |
|                                             |
|  Source of truth for all content and         |
|  metadata. Fractional sort order.            |
+---------------------+-----------------------+
                      |
                      | ValueObservation
                      |
+---------------------+-----------------------+
|              EditorViewState                |
|                                             |
|  Observes outline blocks (headings +        |
|  section breaks) for sidebar display.       |
|  Manages zoom state, editor mode, focus.    |
+---------------------+-----------------------+
                      |
                      |
+---------------------+-----------------------+
|              OutlineSidebar                 |
|                                             |
|  Displays heading blocks as cards.          |
|  Status, tags, word goals write through     |
|  directly to block table on change.         |
+---------------------------------------------+
```

## How the Two Editors Communicate with the Block Layer

The two editors use different mechanisms to map their content to database blocks, because they have fundamentally different document models.

### Milkdown (WYSIWYG)

Milkdown is built on ProseMirror, which represents the document as a tree of typed nodes. Each top-level node (paragraph, heading, code block, etc.) IS a block. A ProseMirror plugin assigns a `blockId` attribute to each top-level node and tracks changes at the node level.

When the user edits:
- The plugin diffs the previous and current document state
- It produces a `BlockChanges` object: which blocks were updated, which were inserted (with temporary IDs), which were deleted
- `BlockSyncService` applies these changes to the database
- For inserts, the database assigns permanent UUIDs and sends them back via `confirmBlockIds()`, which the plugin uses to update node attributes

The plugin does not need to parse markdown or infer block boundaries -- ProseMirror already knows the document structure.

### CodeMirror (Source)

CodeMirror is a plain-text editor. It has no concept of "blocks" -- it sees a flat string. Tracking blocks natively in CodeMirror would require inferring block boundaries from blank lines, code fences, and other structural markers on every keystroke, which is fragile and error-prone.

Instead, block IDs are embedded directly in the markdown as HTML comments:

```markdown
<!-- @bid:a1b2c3d4 -->## Introduction

<!-- @bid:e5f6g7h8 -->This is the first paragraph of the introduction.

<!-- @bid:i9j0k1l2 -->This is the second paragraph.
```

CodeMirror preserves these naturally because it's a plain-text editor. When the sync layer receives content from CodeMirror:
1. Extract all `<!-- @bid:UUID -->` markers and their associated content
2. Match each marker to its database block by UUID
3. Blocks with IDs that appear in the content but changed: update
4. Blocks with IDs that don't appear in the content: delete
5. Content without a preceding ID marker: create as new block

### Mode Switching

When switching between editors:
- **WYSIWYG → Source**: Read block IDs from ProseMirror node attributes, inject `<!-- @bid:UUID -->` comments into the markdown before passing to CodeMirror
- **Source → WYSIWYG**: Extract `<!-- @bid:UUID -->` comments from the markdown, pass clean markdown to Milkdown, and set `blockId` attributes on the corresponding ProseMirror nodes

This is the same pattern the current system uses for `<!-- @sid:UUID -->` section anchors during mode switching.

## Zoom

Zoom is a database operation, not a content operation. The editor doesn't know or care whether it's showing the full document or a zoomed subset.

### Zoom In

1. Look up the heading block by its ID
2. Query the database for all blocks between this heading's sort order and the next heading at the same or higher level (`fetchBlocksInRange`)
3. Assemble those blocks into markdown (`assembleMarkdown`)
4. If source mode, inject `<!-- @bid:UUID -->` anchors
5. Push the markdown to the active editor
6. Record the zoom range (sort order boundaries) for later

### Editing While Zoomed

The editor contains only the zoomed blocks' markdown. Changes sync normally:
- Milkdown reports `BlockChanges` for the zoomed blocks
- CodeMirror content has `<!-- @bid:UUID -->` markers for the zoomed blocks
- New blocks get fractional sort orders between existing zoomed blocks (e.g., 5.5 between 5.0 and 6.0), so they appear in the correct position in the full document
- The rest of the document is untouched in the database

### Zoom Out

1. Fetch ALL blocks from the database
2. Assemble into full markdown
3. Push to editor

No merging logic. No `fullDocumentBeforeZoom` backup. No content slicing. The database always has the complete, correct document. Zoom-out is just "show me everything."

## Metadata Persistence

Heading blocks and section-break blocks carry section metadata: status, tags, word goal, goal type. This metadata is stored directly in the block table row.

When a user changes metadata in the sidebar (clicks a status dot, edits tags, sets a word goal), the change follows two paths simultaneously:

1. **UI binding**: The `@Observable` view model property updates immediately, giving instant visual feedback
2. **Database write**: The corresponding database method (`updateBlockStatus`, `updateBlockTags`, `updateBlockWordGoal`) fires immediately

There is no callback chain, no `onSectionUpdated` closure, no intermediate step. The view model has a reference to the database and writes directly on property change.

If the app crashes between the UI update and the database write (a window of microseconds), the worst case is that one click is lost. On next launch, the UI loads from the database and shows the pre-crash state.

## Sidebar

The sidebar observes `observeOutlineBlocks()`, which returns a GRDB `ValueObservation` stream of heading and section-break blocks, sorted by sort order (with bibliography pinned to the bottom).

Each heading block maps to a card in the sidebar showing:
- Hash bar (heading level) or section-break marker
- Title (heading text or pseudo-section excerpt)
- Status dot (writes through to database on click)
- Tags (write through on edit)
- Word count (computed from all blocks between this heading and the next)

The sidebar does NOT hold a separate copy of the data. It observes the database and re-renders when blocks change. Drag-and-drop reorders blocks by updating their sort orders in the database; the observation fires and the sidebar re-renders.

## State Machine

All content transitions (zoom in, zoom out, editor switch, hierarchy enforcement, drag reorder, bibliography update) go through a single state machine. The state machine has one active state at a time:

- `idle`: Normal operation. Editor polling and database observation are active.
- `zooming`: Zoom transition in progress. Editor content is being swapped.
- `switchingEditor`: Milkdown ↔ CodeMirror transition. Anchors being injected/extracted.
- `reordering`: Drag-drop in progress. Sync suppressed to prevent races.
- `enforcingHierarchy`: Heading levels being adjusted after a structural change.
- `updatingBibliography`: Bibliography section being regenerated.

Each non-idle state has a timeout watchdog. If the state hasn't returned to `idle` within the timeout (e.g., 5 seconds for zoom, 2 seconds for hierarchy enforcement), the watchdog logs a warning and forces a reset to `idle`. This prevents the "permanently stuck" failure mode that the current five-flag system has.

Transitions are explicit: you can only enter a state from `idle`, and you must return to `idle` before entering another state. No overlapping transitions.

## Migration

Existing projects use the section table (schemaVersion=1). On first open after the migration:

1. Read all sections and build a metadata map (title → status, tags, word goal)
2. Read the document markdown from the content table
3. Parse into blocks using `BlockParser`, passing the metadata map so heading blocks inherit their section's status/tags/goals
4. Store blocks in the block table
5. Set the project's schemaVersion to 2

The section table is not deleted -- it stays for backward compatibility. But it is no longer read or written during active editing. All active operations use the block table.
